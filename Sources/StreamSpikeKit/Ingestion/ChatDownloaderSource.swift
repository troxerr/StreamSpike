import Foundation

/// Reads a recording's chat with `chat_downloader`, which appends one JSON object per line to a file.
/// The file is read while the tool runs, so the chart fills in as chat arrives.
public struct ChatDownloaderSource: ChatSource {
    public var executable: String
    public var url: String
    public var limitSeconds: Double?

    public init(executable: String, url: String, limitSeconds: Double? = nil) {
        self.executable = executable
        self.url = url
        self.limitSeconds = limitSeconds
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error> {
        AsyncThrowingStream { continuation in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-chat-\(UUID().uuidString).jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: file) }

            continuation.yield(.status("Downloading chat"))
            var arguments = [url, "--output", file.path, "--interruptible_retry", "false", "--max_attempts", "3"]
            if let limit = limitSeconds { arguments += ["--end_time", String(Int(limit))] }

            let finished = Flag()
            let lines = LineLog()
            let total = Counter()
            let tailer = ChatFileTailer(path: file.path)
            let poller = Task {
                while true {
                    let isLastPass = finished.value
                    let batch = tailer.readNew()
                    if !batch.isEmpty {
                        total.add(batch.count)
                        continuation.yield(.items(batch))
                    }
                    if isLastPass { break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }

            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(executable, arguments, captureStdout: false,
                                                     onStdoutLine: { lines.add($0) }, onStderrLine: { lines.add($0) })
            } catch {
                finished.set()
                poller.cancel()
                throw error
            }
            finished.set()
            await poller.value

            if total.value == 0 {
                let reason = lines.last(where: { $0.contains("[ERROR]") })?.replacingOccurrences(of: "[ERROR] ", with: "")
                    ?? (result.status == 0 ? "No chat messages were found for this video." : "chat_downloader exited with status \(result.status).")
                throw ToolError(reason)
            }
        }
    }
}

/// Reads the lines a tool appends to a file, keeping a half-written last line for the next pass.
/// `locate` returns the file's current path, so a `.part` file renamed when the tool finishes keeps its offset.
final class ChatFileTailer: @unchecked Sendable {
    private let locate: @Sendable () -> String?
    private let parse: @Sendable (Data) -> [ChatMessage]
    private var offset: UInt64 = 0
    private var pending = Data()

    init(path: String, parse: @escaping @Sendable (Data) -> [ChatMessage] = { ChatLineParser.parse($0).map { [$0] } ?? [] }) {
        locate = { path }
        self.parse = parse
    }

    init(locate: @escaping @Sendable () -> String?, parse: @escaping @Sendable (Data) -> [ChatMessage]) {
        self.locate = locate
        self.parse = parse
    }

    func readNew() -> [ChatMessage] {
        guard let path = locate(), let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return [] }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        pending.append(data)
        var messages: [ChatMessage] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            messages += parse(Data(line))
        }
        return messages
    }
}

public enum ChatLineParser {
    private struct Raw: Decodable {
        struct Author: Decodable { var name: String? }
        var time_in_seconds: Double?
        var message: String?
        var author: Author?
    }

    private static let decoder = JSONDecoder()

    /// One `chat_downloader` JSON line. Lines before the video starts, and lines with no text, are dropped.
    public static func parse(_ line: Data) -> ChatMessage? {
        guard let raw = try? decoder.decode(Raw.self, from: line),
              let time = raw.time_in_seconds, time >= 0,
              let text = raw.message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return ChatMessage(time: time, author: raw.author?.name ?? "", text: text)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ n: Int) { lock.withLock { count += n } }
}

final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > 200 { lines.removeFirst(100) }
        }
    }

    func last(where match: (String) -> Bool) -> String? {
        lock.withLock { lines.last(where: match) }
    }
}
