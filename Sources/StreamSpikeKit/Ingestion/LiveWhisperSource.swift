import Foundation

/// A live stream's speech, near real time: ffmpeg reads the live audio and cuts it into 20 s 16 kHz mono
/// WAV chunks, and whisper-cli transcribes each chunk as soon as it is complete. It ends when the stream does.
/// The transcript runs a little behind the chat, by the stream's own latency plus up to one chunk.
public struct LiveWhisperTranscriptSource: TranscriptSource {
    public var ytDlp: String
    public var ffmpeg: String
    public var whisperCLI: String
    public var model: String
    public var url: String
    public var startedAt: Date
    public var chunkSeconds = 20
    public var name: String { "Whisper (live)" }

    public init(ytDlp: String, ffmpeg: String, whisperCLI: String, model: String, url: String, startedAt: Date = Date()) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.whisperCLI = whisperCLI
        self.model = model
        self.url = url
        self.startedAt = startedAt
    }

    /// Ready chunks beyond this many are dropped, oldest first, so a slow Whisper never falls hopelessly behind.
    static let backlogLimit = 6

    public func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            guard FileManager.default.fileExists(atPath: source.model) else {
                throw ToolError("The Whisper model file was not found: \(source.model)")
            }
            var transcribed = 0
            var failedRuns = 0
            while true {
                try Task.checkCancellation()
                continuation.yield(.status(transcribed == 0 ? "Finding the live audio" : "Audio dropped, reconnecting"))
                do {
                    let chunks = try await source.runOnce(continuation)
                    transcribed += chunks
                    // A run that produced chunks means the stream was live; one that did not is a failed attempt.
                    failedRuns = chunks > 0 ? 0 : failedRuns + 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if transcribed == 0 { throw error }
                    failedRuns += 1
                }
                if failedRuns >= 3 {
                    continuation.yield(.status("The stream ended"))
                    return
                }
                try await Task.sleep(for: .seconds(Double(max(1, failedRuns)) * 5))
            }
        }
    }

    /// One ffmpeg run: resolves the audio URL, cuts chunks until ffmpeg exits, and transcribes them as they complete.
    private func runOnce(_ continuation: AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error>.Continuation) async throws -> Int {
        let found = try await ProcessRunner.runChecked(ytDlp, ["-g", "-f", "bestaudio/worst/best", "--no-playlist", "--no-warnings", url])
        guard let audioURL = found.stdout.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.isEmpty }) else {
            throw ToolError("yt-dlp found no live audio. The stream may be offline.")
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let finished = Flag()
        let arguments = ["-hide_banner", "-loglevel", "error", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
                         "-i", audioURL, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-f", "segment",
                         "-segment_time", String(chunkSeconds), "-reset_timestamps", "1",
                         folder.appendingPathComponent("chunk_%05d.wav").path]
        let ffmpeg = ffmpeg
        let ffmpegTask = Task { () -> ProcessResult in
            do {
                let result = try await ProcessRunner.run(ffmpeg, arguments, captureStdout: false)
                finished.set()
                return result
            } catch {
                finished.set()
                throw error
            }
        }
        defer { ffmpegTask.cancel() }

        // Chunk 0 starts when ffmpeg does, so its time on the chart is how long monitoring had run by then.
        let base = Date().timeIntervalSince(startedAt)
        let language = model.hasSuffix(".en.bin") ? "en" : "auto"
        continuation.yield(.status("Transcribing live audio"))
        var done = Set<Int>()
        var failedChunks = 0
        while true {
            try Task.checkCancellation()
            let isOver = finished.value
            let indexes = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .compactMap { name -> Int? in
                    guard name.hasPrefix("chunk_"), name.hasSuffix(".wav") else { return nil }
                    return Int(name.dropFirst(6).dropLast(4))
                }
                .sorted()
            // The newest chunk is still being written until ffmpeg starts the next one, or ends.
            var ready = indexes.filter { !done.contains($0) && (isOver || $0 < (indexes.last ?? 0)) }
            if ready.count > Self.backlogLimit {
                for index in ready.dropLast(Self.backlogLimit) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(String(format: "chunk_%05d.wav", index)))
                    done.insert(index)
                }
                ready = Array(ready.suffix(Self.backlogLimit))
                continuation.yield(.status("Transcript is behind, skipped older audio"))
            }
            for index in ready {
                try Task.checkCancellation()
                let file = folder.appendingPathComponent(String(format: "chunk_%05d.wav", index))
                done.insert(index)
                do {
                    let result = try await ProcessRunner.runChecked(whisperCLI, ["-m", model, "-f", file.path, "-l", language, "-np"])
                    failedChunks = 0
                    let segments = TranscriptParsers.whisper(result.stdout, offset: base + Double(index * chunkSeconds))
                    if !segments.isEmpty { continuation.yield(.items(segments)) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One bad chunk loses 20 s of speech, not the rest of the run. Many in a row mean Whisper itself is broken.
                    failedChunks += 1
                    if failedChunks >= 5 { throw error }
                    continuation.yield(.status("Skipped a chunk Whisper could not read"))
                }
                try? FileManager.default.removeItem(at: file)
            }
            if isOver { break }
            let waiting = indexes.filter { !done.contains($0) }.count
            if waiting > 1 { continuation.yield(.status("Transcript is \(waiting * chunkSeconds) s behind")) }
            try await Task.sleep(for: .seconds(1))
        }

        let result = try await ffmpegTask.value
        if done.isEmpty, result.status != 0 {
            throw ToolError("ffmpeg could not read the live audio: \(ProcessRunner.tail(result.stderr))")
        }
        return done.count
    }
}
