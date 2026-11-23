import Foundation

/// Twitch VOD chat through `twitch-dl chat json`. It writes one JSON file when it finishes, so chat arrives
/// in one piece, with progress while it downloads. It cannot download a part, so a time limit only filters.
public struct TwitchDlChatSource: ChatSource {
    public var executable: String
    public var videoID: String
    public var limitSeconds: Double?

    public init(executable: String, videoID: String, limitSeconds: Double? = nil) {
        self.executable = executable
        self.videoID = videoID
        self.limitSeconds = limitSeconds
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-twitchchat-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("chat.json")

            continuation.yield(.status("Downloading Twitch chat with twitch-dl"))
            let lines = LineLog()
            try await ProcessRunner.runChecked(source.executable, ["chat", "json", source.videoID, "-o", file.path, "--overwrite"],
                                               captureStdout: false, onStdoutLine: { line in
                lines.add(line)
                if let percent = TwitchDlChatSource.progress(line) { continuation.yield(.progress(percent)) }
            }, onStderrLine: { lines.add($0) })

            guard let data = try? Data(contentsOf: file) else { throw ToolError("twitch-dl did not write a chat file.") }
            var messages = TwitchDlChatSource.parse(data)
            if let limit = source.limitSeconds { messages = messages.filter { $0.time <= limit } }
            guard !messages.isEmpty else { throw ToolError("This Twitch video has no chat messages.") }
            for start in stride(from: 0, to: messages.count, by: 5000) {
                continuation.yield(.items(Array(messages[start..<min(start + 5000, messages.count)])))
            }
        }
    }

    /// 0.79 from `Loading Comments 56:38/01:11:38 (79%)`.
    static func progress(_ line: String) -> Double? {
        guard line.contains("Loading Comments"), let open = line.lastIndex(of: "("), let close = line.lastIndex(of: "%"), open < close else { return nil }
        return Double(line[line.index(after: open)..<close]).map { $0 / 100 }
    }

    public static func parse(_ data: Data) -> [ChatMessage] {
        struct Document: Decodable {
            struct Comment: Decodable {
                struct Commenter: Decodable { var displayName: String? }
                struct Message: Decodable {
                    struct Fragment: Decodable { var text: String? }
                    var fragments: [Fragment]?
                }
                var contentOffsetSeconds: Double?
                var commenter: Commenter?
                var message: Message?
            }
            var comments: [Comment]?
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return (document.comments ?? []).compactMap { comment in
            guard let time = comment.contentOffsetSeconds, time >= 0 else { return nil }
            let text = (comment.message?.fragments ?? []).compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatMessage(time: time, author: comment.commenter?.displayName ?? "", text: text)
        }.sorted { $0.time < $1.time }
    }
}
