import Foundation

// Live chat. Every live source stamps a message with the seconds since monitoring began (`startedAt`),
// so the chart's time axis starts at 0 on every platform.

// MARK: - WebSocket loop

/// Keeps a WebSocket open: connects, greets, hands every text message to `handle`, and reconnects with a
/// growing delay when the connection drops. Ends only when the task is cancelled.
enum WebSocketLoop {
    static func run(
        url: URL,
        status: @escaping @Sendable (String) -> Void,
        greeting: @escaping @Sendable (URLSessionWebSocketTask) async throws -> Void,
        handle: @escaping @Sendable (String, URLSessionWebSocketTask) async throws -> Void
    ) async throws {
        var failures = 0
        while !Task.isCancelled {
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()
            do {
                try await withTaskCancellationHandler {
                    try await greeting(task)
                    while true {
                        let message = try await task.receive()
                        failures = 0
                        switch message {
                        case .string(let text): try await handle(text, task)
                        case .data(let data): try await handle(String(decoding: data, as: UTF8.self), task)
                        @unknown default: break
                        }
                    }
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            } catch let fatal as ToolError {
                // A refusal from the server is not a dropped connection: reconnecting would repeat it.
                task.cancel(with: .goingAway, reason: nil)
                throw fatal
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                try Task.checkCancellation()
                failures += 1
                status("Connection lost, reconnecting")
                try await Task.sleep(for: .seconds(min(30, Double(failures) * 2)))
            }
        }
        throw CancellationError()
    }
}

/// Collects messages from a socket callback and hands them over in batches, so a busy chat
/// does not redraw the chart a hundred times a second.
final class MessageBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ChatMessage] = []

    func add(_ message: ChatMessage) {
        lock.withLock { pending.append(message) }
    }

    func drain() -> [ChatMessage] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }

    /// Yields a batch every half second until cancelled.
    func flush(into continuation: AsyncThrowingStream<IngestEvent<ChatMessage>, Error>.Continuation) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let batch = drain()
                if !batch.isEmpty { continuation.yield(.items(batch)) }
            }
        }
    }
}

// MARK: - Twitch IRC

public enum TwitchIRCParser {
    public enum Event: Equatable {
        case ping(String)
        case message(author: String, text: String)
        case other
    }

    /// One IRC line, with or without IRCv3 tags.
    public static func parse(_ line: String) -> Event {
        var rest = Substring(line)
        var tags: [String: String] = [:]
        if rest.hasPrefix("@"), let space = rest.firstIndex(of: " ") {
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { tags[String(parts[0])] = String(parts[1]) }
            }
            rest = rest[rest.index(after: space)...]
        }
        var prefix = ""
        if rest.hasPrefix(":"), let space = rest.firstIndex(of: " ") {
            prefix = String(rest[rest.index(after: rest.startIndex)..<space])
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix("PING") {
            return .ping(rest.dropFirst(4).drop { $0 == " " || $0 == ":" }.description)
        }
        guard rest.hasPrefix("PRIVMSG "), let split = rest.range(of: " :") else { return .other }
        var text = String(rest[split.upperBound...])
        if text.hasPrefix("\u{1}ACTION ") {
            text = String(text.dropFirst(8)).replacingOccurrences(of: "\u{1}", with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .other }
        let nick = prefix.split(separator: "!").first.map(String.init) ?? ""
        let display = (tags["display-name"] ?? "").replacingOccurrences(of: "\\s", with: " ")
        return .message(author: display.isEmpty ? nick : display, text: text)
    }
}

/// Twitch chat over the public IRC WebSocket, signed in anonymously (read only).
public struct TwitchIRCChatSource: ChatSource {
    public var channel: String
    public var startedAt: Date

    public init(channel: String, startedAt: Date = Date()) {
        self.channel = channel.lowercased()
        self.startedAt = startedAt
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            let batcher = MessageBatcher()
            let flusher = batcher.flush(into: continuation)
            defer { flusher.cancel() }
            continuation.yield(.status("Connecting to Twitch chat"))
            let nick = "justinfan\(Int.random(in: 10_000...99_999))"
            try await WebSocketLoop.run(
                url: URL(string: "wss://irc-ws.chat.twitch.tv")!,
                status: { continuation.yield(.status($0)) },
                greeting: { socket in
                    try await socket.send(.string("CAP REQ :twitch.tv/tags"))
                    try await socket.send(.string("PASS SCHMOOPIIE"))
                    try await socket.send(.string("NICK \(nick)"))
                    try await socket.send(.string("JOIN #\(source.channel)"))
                    continuation.yield(.status("Listening to #\(source.channel)"))
                },
                handle: { text, socket in
                    for line in text.split(whereSeparator: \.isNewline) {
                        switch TwitchIRCParser.parse(String(line)) {
                        case .ping(let payload): try await socket.send(.string("PONG :\(payload)"))
                        case .message(let author, let body):
                            batcher.add(ChatMessage(time: Date().timeIntervalSince(source.startedAt), author: author, text: body))
                        case .other: break
                        }
                    }
                })
        }
    }
}

// MARK: - YouTube live chat

/// A live `chat_downloader` line. Live messages have no video offset, so the message's own clock
/// (`timestamp`, microseconds) is turned into seconds since monitoring began.
public struct LiveChatLineParser: Sendable {
    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    private struct Raw: Decodable {
        struct Author: Decodable { var name: String? }
        var timestamp: Double?
        var message: String?
        var author: Author?
    }

    /// Messages from before monitoring began (the backlog `chat_downloader` starts with) are dropped.
    public func parse(_ line: Data) -> ChatMessage? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: line), let micros = raw.timestamp,
              let text = raw.message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let time = micros / 1_000_000 - startedAt.timeIntervalSince1970
        guard time >= -1 else { return nil }
        return ChatMessage(time: max(0, time), author: raw.author?.name ?? "", text: text)
    }
}
