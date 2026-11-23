import Foundation

/// What an ingestion source reports while it runs.
public enum IngestEvent<Item: Sendable>: Sendable {
    /// A line for the progress panel, like "Downloading audio".
    case status(String)
    /// 0 to 1, when the source can tell.
    case progress(Double)
    /// New items. Arrive in batches, in no guaranteed order.
    case items([Item])
}

/// Where chat comes from. A VOD source reads a recording; a live source (Twitch IRC)
/// keeps the stream open and never finishes on its own.
public protocol ChatSource: Sendable {
    func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error>
}

/// Where the streamer's words come from: captions, or local Whisper on audio chunks.
public protocol TranscriptSource: Sendable {
    /// Shown in the UI, like "YouTube captions" or "Whisper".
    var name: String { get }
    func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error>
}

extension AsyncThrowingStream where Failure == Error {
    /// A stream fed by an async body. Cancelling the consumer cancels the body, which stops its processes.
    init(_ body: @escaping @Sendable (Continuation) async throws -> Void) {
        self.init(Element.self) { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct IngestionPlan: Sendable {
    public var chat: any ChatSource
    public var transcript: any TranscriptSource
}

/// Picks the sources for a stream. Live Monitor plugs in here: return a Twitch IRC
/// `ChatSource` and a chunked live `TranscriptSource` for `.live`.
public enum IngestionPlanner {
    /// `startedAt` is time zero for a live run: every chat message and transcript segment is timed from it.
    public static func plan(stream: StreamURL, mode: StreamMode, tools: ToolPaths,
                            limitSeconds: Double?, startedAt: Date = Date()) throws -> IngestionPlan {
        guard stream.supports(mode) else {
            throw ToolError(mode == .vod
                ? "This link is a channel, not a recording. Paste a VOD link, or use Live Monitor."
                : "This link is a recording. Paste a channel link for Live Monitor.")
        }
        if mode == .live { return live(stream: stream, tools: tools, startedAt: startedAt) }

        // chat_downloader streams chat as it goes but breaks when YouTube or Twitch change their pages.
        // On YouTube, yt-dlp reads the same replay and is the fallback.
        let chatDownloader = ChatDownloaderSource(executable: tools.path(for: .chatDownloader), url: stream.link(), limitSeconds: limitSeconds)
        var chat: any ChatSource = chatDownloader
        if stream.platform == .youtube {
            chat = FallbackChatSource(sources: [
                ("chat_downloader", chatDownloader),
                ("yt-dlp", YtDlpChatSource(ytDlp: tools.path(for: .ytDlp), url: stream.link(), limitSeconds: limitSeconds)),
            ])
        } else if stream.platform == .twitch, tools.status(of: .twitchDl).isOK {
            chat = FallbackChatSource(sources: [
                ("chat_downloader", chatDownloader),
                ("twitch-dl", TwitchDlChatSource(executable: tools.path(for: .twitchDl), videoID: stream.id, limitSeconds: limitSeconds)),
            ])
        }
        let whisper = WhisperTranscriptSource(
            ytDlp: tools.path(for: .ytDlp), ffmpeg: tools.path(for: .ffmpeg),
            whisperCLI: tools.path(for: .whisperCLI), model: tools.path(for: .whisperModel),
            url: stream.link(), limitSeconds: limitSeconds)
        let transcript: any TranscriptSource
        if stream.platform == .youtube {
            transcript = FallbackTranscriptSource(sources: [
                YouTubeTranscriptAPISource(executable: tools.path(for: .youtubeTranscriptAPI), videoID: stream.id, limitSeconds: limitSeconds),
                YtDlpCaptionSource(ytDlp: tools.path(for: .ytDlp), url: stream.link(), limitSeconds: limitSeconds),
                whisper,
            ])
        } else {
            transcript = whisper
        }
        return IngestionPlan(chat: chat, transcript: transcript)
    }

    /// Twitch chat over its IRC socket, YouTube chat through chat_downloader and yt-dlp,
    /// and Whisper on chunks of the live audio for both.
    private static func live(stream: StreamURL, tools: ToolPaths, startedAt: Date) -> IngestionPlan {
        let chat: any ChatSource
        switch stream.platform {
        case .twitch: chat = TwitchIRCChatSource(channel: stream.id, startedAt: startedAt)
        case .youtube:
            // chat_downloader is tried first, then yt-dlp's live chat downloader, which survives YouTube's page changes.
            chat = FallbackChatSource(sources: [
                ("chat_downloader", ChatDownloaderSource(executable: tools.path(for: .chatDownloader), url: stream.link(), liveStart: startedAt)),
                ("yt-dlp", YtDlpChatSource(ytDlp: tools.path(for: .ytDlp), url: stream.link(), liveStart: startedAt)),
            ])
        }
        let transcript = LiveWhisperTranscriptSource(
            ytDlp: tools.path(for: .ytDlp), ffmpeg: tools.path(for: .ffmpeg), whisperCLI: tools.path(for: .whisperCLI),
            model: tools.path(for: .whisperModel), url: stream.link(), startedAt: startedAt)
        return IngestionPlan(chat: chat, transcript: transcript)
    }
}
