import Foundation

/// YouTube chat replay through yt-dlp, which tracks YouTube's changes more closely than chat_downloader.
/// yt-dlp saves the replay as a `live_chat` subtitle file, one JSON event per line. The file is read while it grows.
/// yt-dlp cannot stop early, so with a time limit the download is stopped once chat passes it.
public struct YtDlpChatSource: ChatSource {
    public var ytDlp: String
    public var url: String
    public var limitSeconds: Double?
    /// Set for a live stream: yt-dlp keeps polling until stopped, and messages are timed from this moment.
    public var liveStart: Date?

    public init(ytDlp: String, url: String, limitSeconds: Double? = nil, liveStart: Date? = nil) {
        self.ytDlp = ytDlp
        self.url = url
        self.limitSeconds = limitSeconds
        self.liveStart = liveStart
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-ytchat-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            continuation.yield(.status("Downloading chat replay with yt-dlp"))
            let arguments = ["--skip-download", "--write-subs", "--sub-langs", "live_chat", "--no-playlist", "--no-warnings",
                             "--newline", "-o", folder.appendingPathComponent("chat.%(ext)s").path, source.url]
            let lines = LineLog()
            let total = Counter()
            let finished = Flag()
            let reachedLimit = Flag()
            let limit = source.limitSeconds

            let processTask = Task {
                try await ProcessRunner.run(source.ytDlp, arguments, captureStdout: false,
                                            onStdoutLine: { lines.add($0) }, onStderrLine: { lines.add($0) })
            }
            let liveStart = source.liveStart
            let tailer = ChatFileTailer(locate: { YtDlpChatSource.chatFile(in: folder) },
                                        parse: { YouTubeReplayParser.parse($0, liveStart: liveStart) })
            let poller = Task {
                while true {
                    let isLastPass = finished.value
                    var batch = tailer.readNew()
                    if let limit {
                        if batch.contains(where: { $0.time > limit }) {
                            batch = batch.filter { $0.time <= limit }
                            reachedLimit.set()
                            processTask.cancel()
                        }
                    }
                    if !batch.isEmpty {
                        total.add(batch.count)
                        continuation.yield(.items(batch))
                    }
                    if isLastPass || reachedLimit.value { break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }

            var status: Int32 = 0
            do {
                status = try await withTaskCancellationHandler {
                    try await processTask.value.status
                } onCancel: {
                    processTask.cancel()
                }
            } catch is CancellationError {
                // Stopping at the time limit is how a limited run ends. Any other cancel is the caller's.
                guard reachedLimit.value else {
                    finished.set()
                    poller.cancel()
                    throw CancellationError()
                }
            } catch {
                finished.set()
                poller.cancel()
                throw error
            }
            finished.set()
            await poller.value

            if total.value == 0 {
                let reason = lines.last(where: { $0.contains("ERROR") })?.replacingOccurrences(of: "ERROR: ", with: "")
                    ?? (status == 0 ? "yt-dlp found no chat replay for this video." : "yt-dlp exited with status \(status).")
                throw ToolError(reason)
            }
        }
    }

    /// The `live_chat` file yt-dlp is writing, or has finished writing.
    static func chatFile(in folder: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // yt-dlp also leaves `-Frag` files beside the chat file while it downloads.
        let name = names.first { $0.hasPrefix("chat.") && $0.hasSuffix(".live_chat.json") }
            ?? names.first { $0.hasPrefix("chat.") && $0.hasSuffix(".live_chat.json.part") }
        return name.map { folder.appendingPathComponent($0).path }
    }
}

/// One line of a yt-dlp `live_chat` file: a replay action holding zero or more chat events.
public enum YouTubeReplayParser {
    private struct Line: Decodable {
        struct Replay: Decodable {
            var videoOffsetTimeMsec: String?
            var actions: [Action]?
        }
        struct Action: Decodable {
            struct Add: Decodable {
                struct Item: Decodable {
                    var liveChatTextMessageRenderer: Renderer?
                    var liveChatPaidMessageRenderer: Renderer?
                }
                var item: Item?
            }
            var addChatItemAction: Add?
        }
        struct Renderer: Decodable {
            struct Name: Decodable { var simpleText: String? }
            var timestampUsec: String?
            struct Message: Decodable { var runs: [Run]? }
            struct Run: Decodable {
                struct Emoji: Decodable {
                    var emojiId: String?
                    var shortcuts: [String]?
                }
                var text: String?
                var emoji: Emoji?
            }
            var authorName: Name?
            var message: Message?
        }
        var replayChatItemAction: Replay?
    }

    private static let decoder = JSONDecoder()

    /// A recording's lines carry the video offset. A live stream's lines do not, so with `liveStart` each
    /// message is timed from its own clock, and the backlog from before monitoring began is dropped.
    public static func parse(_ line: Data, liveStart: Date? = nil) -> [ChatMessage] {
        guard let replay = (try? decoder.decode(Line.self, from: line))?.replayChatItemAction else { return [] }
        var recordedTime = 0.0
        if liveStart == nil {
            guard let offset = replay.videoOffsetTimeMsec.flatMap(Double.init), offset >= 0 else { return [] }
            recordedTime = offset / 1000
        }
        return (replay.actions ?? []).compactMap { action in
            let item = action.addChatItemAction?.item
            guard let renderer = item?.liveChatTextMessageRenderer ?? item?.liveChatPaidMessageRenderer else { return nil }
            var time = recordedTime
            if let liveStart {
                guard let micros = renderer.timestampUsec.flatMap(Double.init) else { return nil }
                time = micros / 1_000_000 - liveStart.timeIntervalSince1970
                guard time >= -1 else { return nil }
                time = max(0, time)
            }
            let text = (renderer.message?.runs ?? []).map { run -> String in
                if let text = run.text { return text }
                guard let emoji = run.emoji else { return "" }
                // Unicode emoji carry the character itself; channel emotes carry a `:name:` shortcut.
                if let id = emoji.emojiId, !id.contains("/") { return id }
                return emoji.shortcuts?.first ?? ""
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatMessage(time: time, author: renderer.authorName?.simpleText ?? "", text: text)
        }
    }
}

/// Tries each chat source in order. A source that fails before delivering anything hands over to the next.
public struct FallbackChatSource: ChatSource {
    public var sources: [(name: String, source: any ChatSource)]

    public init(sources: [(name: String, source: any ChatSource)]) {
        self.sources = sources
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error> {
        let sources = sources
        return AsyncThrowingStream { continuation in
            var failures: [String] = []
            for (name, source) in sources {
                var produced = false
                do {
                    for try await event in source.stream() {
                        if case .items(let items) = event, !items.isEmpty { produced = true }
                        continuation.yield(event)
                    }
                    if produced { return }
                    failures.append("\(name): no messages")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if produced { throw error }
                    failures.append("\(name): \(error.localizedDescription)")
                    continuation.yield(.status("\(name) failed, trying the next source"))
                }
            }
            throw ToolError(failures.joined(separator: " "))
        }
    }
}
