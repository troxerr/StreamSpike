import AppKit
import SwiftData
import StreamSpikeKit

/// Self-test for agents: runs the app's real functions on a test store, with fake command line tools,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/StreamSpike-self.store ~/Applications/StreamSpike.app/Contents/MacOS/StreamSpike --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
/// SELFTEST_ONLINE=<vod link> also runs the real installed tools on the first minute of that stream.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            await seededStreams(model)
            await exportChecks(model)
            await linkChecks(model)
            await fakeToolPipeline(model)
            await cancelCheck(model)
            if let url = ProcessInfo.processInfo.environment["SELFTEST_ONLINE"], !url.isEmpty {
                await online(model, url: url)
            }
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    // MARK: Checks

    private static func seededStreams(_ model: AppModel) async {
        SeedData.insertSamples(into: model)
        let sessions = model.allSessions()
        check("sample streams are saved", sessions.count == 3, "\(sessions.count)")
        guard let twitch = sessions.first(where: { $0.platform == .twitch }) else { return }
        check("a saved stream keeps its spike count", twitch.spikeCount >= 5, "\(twitch.spikeCount)")

        let runtime = model.runtime(for: twitch)
        await model.prepare(twitch)
        check("reopening loads the chat", runtime.chat.count == twitch.chatCount && runtime.chat.count > 1000, "\(runtime.chat.count)")
        check("reopening loads the transcript", runtime.transcript.count == twitch.segmentCount)
        check("reopening rebuilds the chart buckets", runtime.buckets.count == 540, "\(runtime.buckets.count)")
        check("spikes are ranked by Z-score", runtime.spikes.map(\.zScore) == runtime.spikes.map(\.zScore).sorted(by: >))
        check("every spike has a transcript preview", runtime.spikes.allSatisfy { !$0.transcriptPreview.isEmpty })
        check("the top spike is the 4100 s burst", runtime.spikes.first.map { abs($0.time - 4100) < 15 } ?? false,
              "\(runtime.spikes.first?.time ?? -1)")
        runtime.selectedSpikeID = runtime.spikes.first?.id
        if let spike = runtime.selectedSpike {
            let said = runtime.transcriptWindow(from: spike.time - 30, to: spike.time + 15)
            check("the selected spike pairs T-30 s to T+15 s of transcript", said.count >= 6 && said.count <= 9, "\(said.count)")
            check("the selected spike pairs chat from the same window", runtime.chatWindow(from: spike.time - 30, to: spike.time + 15).count > 50)
        }

        let failed = sessions.first { $0.status == .failed }
        check("a failed stream keeps its reason", failed?.statusDetail.contains("Kick") == true)

        // Settings change the result without a download.
        var strict = SpikeSettings()
        strict.minMessages = 60
        await runtime.recompute(settings: strict, knownDuration: twitch.duration)
        check("a higher message floor finds fewer spikes", runtime.spikes.count < twitch.spikeCount, "\(runtime.spikes.count) vs \(twitch.spikeCount)")
        await runtime.recompute(settings: SpikeSettings(), knownDuration: twitch.duration)
    }

    private static func exportChecks(_ model: AppModel) async {
        guard let session = model.allSessions().first(where: { $0.platform == .twitch }),
              let stream = session.stream, let runtime = model.existingRuntime(session.uuid) else { return }
        let settings = SpikeSettings()
        let rows = SpikeExport.rows(spikes: runtime.spikes, transcript: runtime.transcript, stream: stream, settings: settings)
        check("export has one row per spike", rows.count == runtime.spikes.count)
        if let data = try? SpikeExport.json(title: session.title, stream: stream, rows: rows, settings: settings),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let spikes = object["spikes"] as? [[String: Any]] {
            check("JSON export parses", spikes.count == rows.count)
            check("JSON rows carry a timestamped link", (spikes.first?["url"] as? String)?.contains("?t=") == true)
        } else {
            check("JSON export parses", false)
        }
        let csv = SpikeExport.csv(rows)
        check("CSV export has a header and a row per spike", csv.split(separator: "\n").count == rows.count + 1)
    }

    private static func linkChecks(_ model: AppModel) async {
        check("an invalid link is refused", model.addStream("https://example.com/nope", mode: .vod, limitMinutes: 0) == nil)
        check("the refusal explains itself", model.alertMessage?.contains("YouTube, Twitch, or Kick") == true)
        model.alertMessage = nil
        check("Live Monitor is refused with a clear reason", {
            guard let url = StreamURL.parse("twitch.tv/somechannel") else { return false }
            do { _ = try IngestionPlanner.plan(stream: url, mode: .live, tools: ToolPaths(), limitSeconds: nil); return false }
            catch { return error.localizedDescription.contains("Live Monitor") }
        }())
        check("a channel link is refused in VOD mode", {
            guard let url = StreamURL.parse("twitch.tv/somechannel") else { return false }
            return (try? IngestionPlanner.plan(stream: url, mode: .vod, tools: ToolPaths(), limitSeconds: nil)) == nil
        }())
        let paths = ToolPaths(paths: [.ytDlp: "/nonexistent/yt-dlp"])
        check("a missing tool reports as missing", paths.status(of: .ytDlp) == .missing)
        check("the banner lists a missing tool", paths.missing().contains(.ytDlp))
    }

    /// The whole pipeline with fake tools: metadata, chat tailing, caption fallbacks, audio chunks, Whisper, saving, reopening.
    private static func fakeToolPipeline(_ model: AppModel) async {
        let folder = URL(fileURLWithPath: "/tmp/StreamSpike-selftest-tools")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func script(_ name: String, _ body: String) -> String {
            let url = folder.appendingPathComponent(name)
            try? ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let ytDlp = script("yt-dlp", """
        case "$*" in
          *--dump-single-json*) echo '{"title":"Fake Stream","channel":"Fake Channel","duration":120,"is_live":false}'; exit 0;;
          *--skip-download*) exit 0;;
        esac
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
        echo "[download]  50.0% of 1.00MiB"
        echo audio > "$(echo "$out" | sed 's/%(ext)s/m4a/')"
        echo "[download] 100% of 1.00MiB"
        """)
        let ffmpeg = script("ffmpeg", """
        for a; do last="$a"; done
        dir=$(dirname "$last")
        printf RIFF > "$dir/chunk_00000.wav"; printf RIFF > "$dir/chunk_00001.wav"; printf RIFF > "$dir/chunk_00002.wav"
        """)
        let whisper = script("whisper-cli", """
        while [ $# -gt 0 ]; do if [ "$1" = "-f" ]; then f="$2"; fi; shift; done
        echo "[00:00:00.000 --> 00:00:04.000]   Words from $(basename "$f")"
        echo "[00:00:04.000 --> 00:00:06.000]   [BLANK_AUDIO]"
        """)
        let chat = script("chat_downloader", """
        while [ $# -gt 0 ]; do if [ "$1" = "--output" ]; then out="$2"; fi; shift; done
        i=0; while [ $i -lt 60 ]; do echo "{\\"message\\":\\"KEKW $i\\",\\"time_in_seconds\\":$i,\\"author\\":{\\"name\\":\\"u\\"}}" >> "$out"; i=$((i+1)); done
        sleep 1.4
        while [ $i -lt 120 ]; do echo "{\\"message\\":\\"hello $i\\",\\"time_in_seconds\\":$i,\\"author\\":{\\"name\\":\\"u\\"}}" >> "$out"; i=$((i+1)); done
        """)
        let captions = script("youtube_transcript_api", "echo 'no captions' >&2; exit 1")
        let modelFile = folder.appendingPathComponent("model.en.bin")
        try? Data("x".utf8).write(to: modelFile)

        let settings = model.settings
        let saved = settings.overrides
        settings.setPath(ytDlp, for: .ytDlp)
        settings.setPath(ffmpeg, for: .ffmpeg)
        settings.setPath(whisper, for: .whisperCLI)
        settings.setPath(chat, for: .chatDownloader)
        settings.setPath(captions, for: .youtubeTranscriptAPI)
        settings.setPath(modelFile.path, for: .whisperModel)
        check("fake tools show as installed", settings.missing.isEmpty, "\(settings.missing)")

        // Chat tailing alone: two batches, one second apart.
        var batches = 0, total = 0
        let source = ChatDownloaderSource(executable: chat, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        do {
            for try await event in source.stream() {
                if case .items(let items) = event { batches += 1; total += items.count }
            }
        } catch {
            check("chat source runs", false, error.localizedDescription)
        }
        check("chat arrives in batches while the tool runs", batches >= 2 && total == 120, "\(batches) batches, \(total) messages")

        let session = model.addStream("https://www.youtube.com/watch?v=dQw4w9WgXcQ", mode: .vod, limitMinutes: 0)
        check("adding a valid link starts a session", session != nil)
        if let session {
            let finished = await wait { session.status != .running && session.status != .queued }
            check("the pipeline finishes", finished, "\(session.status)")
            check("the pipeline completes", session.status == .complete, "\(session.status): \(session.statusDetail)")
            check("stream details fill in the title", session.title == "Fake Stream" && session.channel == "Fake Channel", session.title)
            check("all chat is saved", session.chatCount == 120, "\(session.chatCount)")
            check("transcript falls back through captions to Whisper", model.existingRuntime(session.uuid)?.transcriptSource == "Whisper",
                  model.existingRuntime(session.uuid)?.transcriptSource ?? "nil")
            check("Whisper chunks are offset by 20 s and noise is dropped", session.segmentCount == 3, "\(session.segmentCount)")
            check("the transcript is saved sorted", {
                let starts = SessionCodec.decode([TranscriptSegment].self, from: session.transcriptData)?.map(\.start) ?? []
                return starts == [0, 20, 40]
            }())
            // Reopen from the database.
            let fresh = SessionRuntime()
            await fresh.load(session: session, settings: settings.detection)
            check("a finished stream reopens from the database", fresh.chat.count == 120 && fresh.transcript.count == 3, "\(fresh.chat.count)")
            check("reopened chart covers the stream length", fresh.buckets.count == 12, "\(fresh.buckets.count)")
            model.remove(session)
            check("deleting a stream removes it", !model.allSessions().contains { $0.uuid == session.uuid })
        }

        // A tool that fails shows its own message.
        let broken = script("chat_downloader_broken", "echo '[ERROR] Live chat replay was turned off for this video.'; exit 0")
        settings.setPath(broken, for: .chatDownloader)
        if let failing = model.addStream("https://www.youtube.com/watch?v=aaaaaaaaaaa", mode: .vod, limitMinutes: 0) {
            _ = await wait { failing.status != .running && failing.status != .queued }
            check("a chat failure fails the stream with the tool's reason", failing.status == .failed && failing.statusDetail.contains("replay was turned off"),
                  "\(failing.status): \(failing.statusDetail)")
            model.remove(failing)
        }

        for dependency in Dependency.allCases { settings.setPath(saved[dependency.rawValue] ?? "", for: dependency) }
    }

    private static func cancelCheck(_ model: AppModel) async {
        let folder = URL(fileURLWithPath: "/tmp/StreamSpike-selftest-tools")
        let slow = folder.appendingPathComponent("chat_downloader_slow").path
        try? "#!/bin/sh\nwhile [ $# -gt 0 ]; do if [ \"$1\" = \"--output\" ]; then out=\"$2\"; fi; shift; done\ni=0; while [ $i -lt 600 ]; do echo \"{\\\"message\\\":\\\"hi $i\\\",\\\"time_in_seconds\\\":$i,\\\"author\\\":{\\\"name\\\":\\\"u\\\"}}\" >> \"$out\"; i=$((i+1)); sleep 0.1; done\n"
            .write(to: URL(fileURLWithPath: slow), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow)
        let settings = model.settings
        settings.setPath(slow, for: .chatDownloader)
        if let session = model.addStream("https://www.youtube.com/watch?v=bbbbbbbbbbb", mode: .vod, limitMinutes: 0) {
            let runtime = model.runtime(for: session)
            _ = await wait { runtime.chat.count > 5 }
            check("chat streams into the chart while the tool runs", runtime.chat.count > 5 && !runtime.buckets.isEmpty || runtime.isRunning, "\(runtime.chat.count)")
            model.cancel(session)
            _ = await wait { session.status != .running }
            check("Stop keeps what arrived", session.status == .cancelled && session.chatCount > 5, "\(session.status) \(session.chatCount)")
            let leftover = await processRunning(named: "chat_downloader_slow")
            check("Stop ends the tool's process", !leftover)
            model.remove(session)
        }
        settings.resetPath(for: .chatDownloader)
    }

    /// Each real stage on its own, so one broken tool does not hide the others.
    private static func online(_ model: AppModel, url: String) async {
        print("ONLINE running the real tools on \(url) (first 150 s)")
        guard let stream = StreamURL.parse(url) else { check("online link accepted", false); return }
        let tools = model.settings.toolPaths
        do {
            let meta = try await MetadataFetcher.fetch(ytDlp: tools.path(for: .ytDlp), url: stream.link())
            print("ONLINE metadata: \(meta.title) | \(meta.channel) | \(meta.duration ?? 0) s")
            check("online: yt-dlp reads the stream details", !meta.title.isEmpty)
        } catch {
            check("online: yt-dlp reads the stream details", false, error.localizedDescription)
        }

        func collect(_ source: any TranscriptSource) async -> (segments: [TranscriptSegment], error: String?) {
            var all: [TranscriptSegment] = []
            do {
                for try await event in source.stream() {
                    if case .items(let items) = event { all += items }
                }
                return (all, nil)
            } catch { return (all, error.localizedDescription) }
        }
        if let plan = try? IngestionPlanner.plan(stream: stream, mode: .vod, tools: tools, limitSeconds: 150) {
            let result = await collect(plan.transcript)
            print("ONLINE transcript chain: \(result.segments.count) segments, first: \(result.segments.first?.text ?? "-")")
            check("online: the transcript chain produces text", !result.segments.isEmpty, result.error ?? "")
        }
        let whisper = WhisperTranscriptSource(ytDlp: tools.path(for: .ytDlp), ffmpeg: tools.path(for: .ffmpeg),
                                              whisperCLI: tools.path(for: .whisperCLI), model: tools.path(for: .whisperModel),
                                              url: stream.link(), limitSeconds: 150)
        let spoken = await collect(whisper)
        print("ONLINE whisper: \(spoken.segments.count) segments, last end \(spoken.segments.map(\.end).max() ?? 0) s, first: \(spoken.segments.sorted { $0.start < $1.start }.first?.text ?? "-")")
        check("online: Whisper transcribes the audio", !spoken.segments.isEmpty, spoken.error ?? "")

        // Chat through the same chain the app uses: chat_downloader, then yt-dlp (YouTube) or twitch-dl (Twitch).
        var chat: [ChatMessage] = []
        var statuses: [String] = []
        do {
            let plan = try IngestionPlanner.plan(stream: stream, mode: .vod, tools: tools, limitSeconds: 150)
            for try await event in plan.chat.stream() {
                switch event {
                case .items(let items): chat += items
                case .status(let text): statuses.append(text)
                case .progress: break
                }
            }
        } catch {
            print("ONLINE chat failed: \(error.localizedDescription)")
        }
        print("ONLINE chat: \(chat.count) messages up to \(chat.map(\.time).max() ?? 0) s; steps: \(statuses.joined(separator: " > "))")
        if let first = chat.first { print("ONLINE first message: \(first.author): \(first.text)") }
        let analysis = SpikeDetector.analyze(messages: chat, settings: SpikeSettings())
        print("ONLINE spikes found: \(analysis.spikes.count)")
        check("online: chat downloads", !chat.isEmpty)
    }

    // MARK: Helpers

    private static func wait(seconds: Double = 30, until condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func processRunning(named name: String) async -> Bool {
        try? await Task.sleep(for: .milliseconds(500))
        let result = try? await ProcessRunner.run("/usr/bin/pgrep", ["-f", name])
        return result?.status == 0
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
