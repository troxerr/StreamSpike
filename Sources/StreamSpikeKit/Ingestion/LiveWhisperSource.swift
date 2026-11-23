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

    public func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            guard FileManager.default.fileExists(atPath: source.model) else {
                throw ToolError("The Whisper model file was not found: \(source.model)")
            }
            continuation.yield(.status("Finding the live audio"))
            let found = try await ProcessRunner.runChecked(source.ytDlp, ["-g", "-f", "bestaudio/worst/best", "--no-playlist", "--no-warnings", source.url])
            guard let audioURL = found.stdout.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.isEmpty }) else {
                throw ToolError("yt-dlp found no live audio. The stream may be offline.")
            }

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let finished = Flag()
            let arguments = ["-hide_banner", "-loglevel", "error", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
                             "-i", audioURL, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-f", "segment",
                             "-segment_time", String(source.chunkSeconds), "-reset_timestamps", "1",
                             folder.appendingPathComponent("chunk_%05d.wav").path]
            let ffmpegTask = Task { () -> ProcessResult in
                do {
                    let result = try await ProcessRunner.run(source.ffmpeg, arguments, captureStdout: false)
                    finished.set()
                    return result
                } catch {
                    finished.set()
                    throw error
                }
            }
            defer { ffmpegTask.cancel() }

            // Chunk 0 starts when ffmpeg does, so its time on the chart is how long monitoring had run by then.
            let base = Date().timeIntervalSince(source.startedAt)
            let language = source.model.hasSuffix(".en.bin") ? "en" : "auto"
            continuation.yield(.status("Transcribing live audio"))
            var done = Set<Int>()
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
                for index in indexes where !done.contains(index) && (isOver || index < (indexes.last ?? 0)) {
                    let file = folder.appendingPathComponent(String(format: "chunk_%05d.wav", index))
                    let result = try await ProcessRunner.runChecked(source.whisperCLI, ["-m", source.model, "-f", file.path, "-l", language, "-np"])
                    try? FileManager.default.removeItem(at: file)
                    done.insert(index)
                    let segments = TranscriptParsers.whisper(result.stdout, offset: base + Double(index * source.chunkSeconds))
                    if !segments.isEmpty { continuation.yield(.items(segments)) }
                }
                if isOver { break }
                try await Task.sleep(for: .seconds(1))
            }

            let result = try await ffmpegTask.value
            if done.isEmpty, result.status != 0 {
                throw ToolError("ffmpeg could not read the live audio: \(ProcessRunner.tail(result.stderr))")
            }
            continuation.yield(.status("The stream ended"))
        }
    }
}
