import Foundation

// MARK: - Parsers

public enum TranscriptParsers {
    /// `youtube_transcript_api --format json`: a list with one list of `{text, start, duration}` per video.
    public static func youtubeTranscriptAPI(_ json: String) -> [TranscriptSegment] {
        struct Item: Decodable { var text: String; var start: Double; var duration: Double? }
        guard let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let items = (try? decoder.decode([[Item]].self, from: data))?.first ?? (try? decoder.decode([Item].self, from: data)) ?? []
        return items.compactMap { item in
            let text = clean(item.text)
            return text.isEmpty ? nil : TranscriptSegment(start: item.start, end: item.start + (item.duration ?? 2), text: text)
        }
    }

    /// yt-dlp's `json3` subtitle format.
    public static func json3(_ data: Data) -> [TranscriptSegment] {
        struct Document: Decodable {
            struct Event: Decodable {
                struct Seg: Decodable { var utf8: String? }
                var tStartMs: Double?
                var dDurationMs: Double?
                var segs: [Seg]?
            }
            var events: [Event]?
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return (document.events ?? []).compactMap { event in
            guard let start = event.tStartMs, let segs = event.segs else { return nil }
            let text = clean(segs.compactMap(\.utf8).joined())
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(start: start / 1000, end: (start + (event.dDurationMs ?? 2000)) / 1000, text: text)
        }
    }

    /// Lines like `[00:00:01.000 --> 00:00:04.320]   Hello chat`, shifted by `offset` seconds.
    public static func whisper(_ output: String, offset: Double) -> [TranscriptSegment] {
        let pattern = /\[(\d+):(\d+):(\d+)\.(\d+)\s*-->\s*(\d+):(\d+):(\d+)\.(\d+)\]\s*(.*)/
        var segments: [TranscriptSegment] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            func seconds(_ h: Substring, _ m: Substring, _ s: Substring, _ ms: Substring) -> Double {
                (Double(h) ?? 0) * 3600 + (Double(m) ?? 0) * 60 + (Double(s) ?? 0) + (Double("0." + ms) ?? 0)
            }
            let text = clean(String(match.output.9))
            guard !text.isEmpty, !isNoise(text) else { continue }
            segments.append(TranscriptSegment(
                start: offset + seconds(match.output.1, match.output.2, match.output.3, match.output.4),
                end: offset + seconds(match.output.5, match.output.6, match.output.7, match.output.8),
                text: text))
        }
        return segments
    }

    /// 12.3 from `[download]  12.3% of 40.00MiB at ...`.
    public static func downloadPercent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]"), let sign = line.firstIndex(of: "%") else { return nil }
        let number = line[line.index(line.startIndex, offsetBy: "[download]".count)..<sign].trimmingCharacters(in: .whitespaces)
        return Double(number)
    }

    /// `[BLANK_AUDIO]`, `(music)`, `*applause*`: Whisper's notes about sound, not speech.
    static func isNoise(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last, text.count < 40 else { return false }
        return ("[(*♪".contains(first) && "])*♪".contains(last)) || text == "you"
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - YouTube captions

/// Existing captions, through `youtube_transcript_api`.
public struct YouTubeTranscriptAPISource: TranscriptSource {
    public var executable: String
    public var videoID: String
    public var limitSeconds: Double?
    public var name: String { "YouTube captions" }

    public init(executable: String, videoID: String, limitSeconds: Double? = nil) {
        self.executable = executable
        self.videoID = videoID
        self.limitSeconds = limitSeconds
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.status("Fetching YouTube captions"))
            let result = try await ProcessRunner.runChecked(executable, [videoID, "--languages", "en", "en-US", "en-GB", "--format", "json"])
            var segments = TranscriptParsers.youtubeTranscriptAPI(result.stdout)
            if let limit = limitSeconds { segments = segments.filter { $0.start <= limit } }
            guard !segments.isEmpty else { throw ToolError("This video has no English captions.") }
            continuation.yield(.items(segments))
            continuation.yield(.progress(1))
        }
    }
}

/// The same captions through yt-dlp, for when `youtube_transcript_api` is missing or blocked.
public struct YtDlpCaptionSource: TranscriptSource {
    public var ytDlp: String
    public var url: String
    public var limitSeconds: Double?
    public var name: String { "YouTube captions (yt-dlp)" }

    public init(ytDlp: String, url: String, limitSeconds: Double? = nil) {
        self.ytDlp = ytDlp
        self.url = url
        self.limitSeconds = limitSeconds
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.status("Fetching captions with yt-dlp"))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-subs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            _ = try await ProcessRunner.run(ytDlp, [
                "--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", "en.*,en",
                "--sub-format", "json3", "--no-playlist", "--no-warnings", "--newline",
                "-o", folder.appendingPathComponent("subs.%(ext)s").path, url,
            ], captureStdout: false)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let file = files.first(where: { $0.pathExtension == "json3" }), let data = try? Data(contentsOf: file) else {
                throw ToolError("yt-dlp found no English captions.")
            }
            var segments = TranscriptParsers.json3(data)
            if let limit = limitSeconds { segments = segments.filter { $0.start <= limit } }
            guard !segments.isEmpty else { throw ToolError("The caption file was empty.") }
            continuation.yield(.items(segments))
            continuation.yield(.progress(1))
        }
    }
}

// MARK: - Whisper

/// Downloads the audio with yt-dlp, cuts it into 16 kHz mono WAV chunks with ffmpeg,
/// and transcribes each chunk with whisper-cli. Chunks arrive as they finish.
public struct WhisperTranscriptSource: TranscriptSource {
    public var ytDlp: String
    public var ffmpeg: String
    public var whisperCLI: String
    public var model: String
    public var url: String
    public var limitSeconds: Double?
    public var chunkSeconds = 20
    public var concurrency = 3
    public var name: String { "Whisper" }

    public init(ytDlp: String, ffmpeg: String, whisperCLI: String, model: String, url: String, limitSeconds: Double? = nil) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.whisperCLI = whisperCLI
        self.model = model
        self.url = url
        self.limitSeconds = limitSeconds
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error> {
        let source = self
        return AsyncThrowingStream { continuation in
            guard FileManager.default.fileExists(atPath: source.model) else {
                throw ToolError("The Whisper model file was not found: \(source.model)")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-audio-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            // 1. Audio only, as small as the platform offers.
            continuation.yield(.status("Downloading audio"))
            var download = ["-f", "bestaudio/worst/best", "--no-playlist", "--newline", "--no-warnings",
                            "--ffmpeg-location", source.ffmpeg, "-o", folder.appendingPathComponent("audio.%(ext)s").path]
            if let limit = source.limitSeconds { download += ["--download-sections", "*0-\(Int(limit))"] }
            download.append(source.url)
            try await ProcessRunner.runChecked(source.ytDlp, download, captureStdout: false, onStdoutLine: { line in
                if let value = TranscriptParsers.downloadPercent(line) {
                    continuation.yield(.progress(value / 100 * 0.3))
                }
            })
            let audio = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("audio.") && $0.pathExtension != "part" }
            guard let audio else { throw ToolError("yt-dlp did not produce an audio file.") }

            // 2. 16 kHz mono WAV, cut into chunks.
            continuation.yield(.status("Converting audio"))
            var convert = ["-y", "-hide_banner", "-loglevel", "error", "-i", audio.path]
            if let limit = source.limitSeconds { convert += ["-t", String(Int(limit))] }
            convert += ["-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-f", "segment",
                        "-segment_time", String(source.chunkSeconds), "-reset_timestamps", "1",
                        folder.appendingPathComponent("chunk_%05d.wav").path]
            try await ProcessRunner.runChecked(source.ffmpeg, convert, captureStdout: false)
            try? FileManager.default.removeItem(at: audio)
            let chunks = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("chunk_") && $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !chunks.isEmpty else { throw ToolError("ffmpeg produced no audio chunks.") }
            continuation.yield(.progress(0.35))

            // 3. Transcribe a few chunks at a time.
            continuation.yield(.status("Transcribing with Whisper"))
            let language = source.model.hasSuffix(".en.bin") ? "en" : "auto"
            let work: @Sendable (Int) async throws -> (Int, [TranscriptSegment]) = { index in
                let result = try await ProcessRunner.runChecked(source.whisperCLI, [
                    "-m", source.model, "-f", chunks[index].path, "-l", language, "-np",
                ])
                let offset = Double(index * source.chunkSeconds)
                try? FileManager.default.removeItem(at: chunks[index])
                return (index, TranscriptParsers.whisper(result.stdout, offset: offset))
            }
            try await withThrowingTaskGroup(of: (Int, [TranscriptSegment]).self) { group in
                var next = 0, done = 0
                while next < min(source.concurrency, chunks.count) {
                    let index = next
                    group.addTask { try await work(index) }
                    next += 1
                }
                while let (_, segments) = try await group.next() {
                    done += 1
                    if !segments.isEmpty { continuation.yield(.items(segments)) }
                    continuation.yield(.progress(0.35 + 0.65 * Double(done) / Double(chunks.count)))
                    if next < chunks.count {
                        let index = next
                        group.addTask { try await work(index) }
                        next += 1
                    }
                }
            }
        }
    }
}

// MARK: - Fallback

/// Tries each source in order and uses the first one that produces a transcript.
public struct FallbackTranscriptSource: TranscriptSource {
    public var sources: [any TranscriptSource]
    public var name: String { sources.first?.name ?? "Transcript" }

    public init(sources: [any TranscriptSource]) {
        self.sources = sources
    }

    public func stream() -> AsyncThrowingStream<IngestEvent<TranscriptSegment>, Error> {
        let sources = sources
        return AsyncThrowingStream { continuation in
            var failures: [String] = []
            for source in sources {
                continuation.yield(.status("Transcript: \(source.name)"))
                var produced = false
                do {
                    for try await event in source.stream() {
                        if case .items(let items) = event, !items.isEmpty { produced = true }
                        continuation.yield(event)
                    }
                    if produced { return }
                    failures.append("\(source.name): no text")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Once a source has delivered text, a late failure keeps what it delivered.
                    if produced { throw error }
                    failures.append("\(source.name): \(error.localizedDescription)")
                }
            }
            throw ToolError("No transcript. " + failures.joined(separator: " "))
        }
    }
}
