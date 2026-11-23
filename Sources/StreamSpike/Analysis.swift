import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import StreamSpikeKit

enum ExportFormat {
    case json, csv

    var fileExtension: String { self == .json ? "json" : "csv" }
    var contentType: UTType { self == .json ? .json : .commaSeparatedText }
}

extension AppModel {
    // MARK: Adding

    /// Makes a session from a pasted link and starts its analysis. Returns nil with `alertMessage` set when the link cannot be used.
    @discardableResult
    func addStream(_ text: String, mode: StreamMode, limitMinutes: Int) -> StreamSession? {
        guard let url = StreamURL.parse(text) else {
            alertMessage = "That is not a YouTube or Twitch link."
            return nil
        }
        let session = StreamSession(url: url, mode: mode, limitSeconds: Double(max(0, limitMinutes)) * 60)
        context.insert(session)
        try? context.save()
        selection = session.uuid
        start(session)
        return session
    }

    // MARK: Running

    /// Downloads chat and the transcript, then finds spikes. Replaces what the session held.
    func start(_ session: StreamSession) {
        let runtime = runtime(for: session)
        guard runtime.task == nil else { return }
        runtime.reset()
        session.status = .running
        session.statusDetail = ""
        runtime.phase = .running
        runtime.task = Task { [weak self] in
            guard let self else { return }
            await self.run(session, runtime)
            runtime.task = nil
        }
    }

    /// Downloads a recording again. A live session is never overwritten: monitoring again makes a new session.
    func restart(_ session: StreamSession) {
        if session.mode == .live {
            addStream(session.urlString, mode: .live, limitMinutes: 0)
        } else {
            start(session)
        }
    }

    func cancel(_ session: StreamSession) {
        runtimes[session.uuid]?.task?.cancel()
    }

    private func run(_ session: StreamSession, _ runtime: SessionRuntime) async {
        let tools = settings.toolPaths
        let limit: Double? = session.limitSeconds > 0 ? session.limitSeconds : nil
        var failure: String?
        var cancelled = false

        guard let stream = session.stream else {
            await finish(session, runtime, failure: "The saved link can no longer be read.", cancelled: false, live: false)
            return
        }

        // A live run is timed from now: chat and speech both count seconds from this moment.
        let isLive = session.mode == .live
        let startedAt = Date()
        if isLive { runtime.liveStart = startedAt }

        runtime.chatStatus = "Reading stream details"
        if let meta = try? await MetadataFetcher.fetch(ytDlp: tools.path(for: .ytDlp), url: stream.link()) {
            session.title = meta.title
            session.channel = meta.channel
            if !isLive {
                session.duration = meta.duration ?? 0
                if let limit, session.duration > 0 { session.duration = min(session.duration, limit) }
            }
        } else if Task.isCancelled == false {
            runtime.warnings.append(isLive
                ? "Stream details were not available. Is the stream live?"
                : "Stream details were not available, so the length is estimated from chat.")
        }
        let knownDuration: Double? = !isLive && session.duration > 0 ? session.duration : nil
        runtime.duration = knownDuration ?? 0
        let duration: @MainActor () -> Double? = { isLive ? Date().timeIntervalSince(startedAt) : knownDuration }

        do {
            let plan = try IngestionPlanner.plan(stream: stream, mode: session.mode, tools: tools, limitSeconds: limit, startedAt: startedAt)
            runtime.chatStatus = "Starting chat download"
            runtime.transcriptStatus = "Starting transcript"
            let refresher = Task { [weak self] in
                guard let self else { return }
                await runtime.refreshLoop(settings: { self.settings.detection }, knownDuration: duration, always: isLive)
            }
            defer { refresher.cancel() }
            // A long live session is saved every minute, so a crash loses little.
            let autosave = Task { [weak self] in
                guard isLive else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, !Task.isCancelled else { return }
                    await self.persist(session, runtime)
                }
            }
            defer { autosave.cancel() }

            let chatTask = Task { try await self.consumeChat(plan.chat, runtime, knownDuration: knownDuration) }
            let transcriptTask = Task { await self.consumeTranscript(plan.transcript, runtime) }
            try await withTaskCancellationHandler {
                do {
                    try await chatTask.value
                } catch {
                    // Without chat there is nothing to chart, so the transcript is not worth waiting for.
                    transcriptTask.cancel()
                    await transcriptTask.value
                    throw error
                }
                await transcriptTask.value
            } onCancel: {
                chatTask.cancel()
                transcriptTask.cancel()
            }
        } catch is CancellationError {
            cancelled = true
        } catch {
            if Task.isCancelled { cancelled = true } else { failure = error.localizedDescription }
        }
        if Task.isCancelled { cancelled = true }
        await finish(session, runtime, failure: failure, cancelled: cancelled, live: isLive)
    }

    private func consumeChat(_ source: any ChatSource, _ runtime: SessionRuntime, knownDuration: Double?) async throws {
        for try await event in source.stream() {
            switch event {
            case .status(let text): runtime.chatStatus = text
            case .progress(let value): runtime.chatFraction = value
            case .items(let batch):
                runtime.append(chat: batch)
                runtime.chatStatus = "\(runtime.chat.count.formatted()) messages"
                if let knownDuration, knownDuration > 0 { runtime.chatFraction = min(1, runtime.chatReach / knownDuration) }
            }
        }
        runtime.chatFraction = 1
        runtime.chatStatus = "\(runtime.chat.count.formatted()) messages"
    }

    /// A transcript that cannot be found is a warning, not a failure: the chart and spikes still work.
    private func consumeTranscript(_ source: any TranscriptSource, _ runtime: SessionRuntime) async {
        do {
            for try await event in source.stream() {
                switch event {
                case .status(let text):
                    runtime.transcriptStatus = text
                    if text.hasPrefix("Transcript: ") { runtime.transcriptSource = String(text.dropFirst("Transcript: ".count)) }
                case .progress(let value): runtime.transcriptFraction = value
                case .items(let batch): runtime.append(transcript: batch)
                }
            }
            runtime.transcriptFraction = 1
            runtime.transcriptStatus = "\(runtime.transcript.count.formatted()) segments"
        } catch is CancellationError {
            return
        } catch {
            runtime.transcriptStatus = "No transcript"
            runtime.warnings.append(error.localizedDescription)
        }
    }

    /// Final analysis, then save. Keeps whatever arrived when a run is stopped.
    private func finish(_ session: StreamSession, _ runtime: SessionRuntime, failure: String?, cancelled: Bool, live: Bool) async {
        runtime.redetectTask?.cancel()
        let sorted = await Task.detached { [chat = runtime.chat] in chat.sorted { $0.time < $1.time } }.value
        runtime.chat = sorted
        if let failure, runtime.chat.isEmpty {
            runtime.phase = .failed(failure)
            session.status = .failed
            session.statusDetail = failure
            try? context.save()
            return
        }
        // A live run ends at the moment it stopped.
        if live, let start = runtime.liveStart { session.duration = Date().timeIntervalSince(start) }
        let known: Double? = session.duration > 0 ? session.duration : nil
        // A stopped run is a cancelled task, which would skip the final analysis. Run it in a fresh one.
        let detection = settings.detection
        await Task { await runtime.recompute(settings: detection, knownDuration: known) }.value
        if session.duration == 0 { session.duration = runtime.duration }
        runtime.transcript.sort { $0.start < $1.start }
        runtime.phase = .finished
        // Stopping is how a live run normally ends.
        session.status = cancelled && !live ? .cancelled : .complete
        session.statusDetail = live ? (cancelled ? "Monitoring stopped." : "The stream ended.")
            : (cancelled ? "Stopped. Kept what was downloaded." : (failure ?? runtime.warnings.first ?? ""))
        await persist(session, runtime)
    }

    /// Saves chat, transcript, and spikes as compressed blobs.
    func persist(_ session: StreamSession, _ runtime: SessionRuntime) async {
        let chat = runtime.chat, transcript = runtime.transcript, spikes = runtime.spikes
        let blobs = await Task.detached {
            (SessionCodec.encode(chat), SessionCodec.encode(transcript), SessionCodec.encode(spikes))
        }.value
        session.chatData = blobs.0
        session.transcriptData = blobs.1
        session.spikesData = blobs.2
        session.chatCount = chat.count
        session.segmentCount = transcript.count
        session.spikeCount = spikes.count
        session.transcriptSource = runtime.transcriptSource
        try? context.save()
    }

    /// Settings changed: find spikes again from the saved chat, without downloading anything.
    func redetect(_ session: StreamSession) {
        let runtime = runtime(for: session)
        guard runtime.phase == .finished else { return }
        runtime.redetectTask?.cancel()
        runtime.redetectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await runtime.recompute(settings: self.settings.detection, knownDuration: session.duration > 0 ? session.duration : nil)
            guard !Task.isCancelled else { return }
            session.spikeCount = runtime.spikes.count
            session.spikesData = SessionCodec.encode(runtime.spikes)
            try? self.context.save()
        }
    }

    // MARK: Sharing

    /// A link to the selected spike's synced window, or to the stream when no spike is selected.
    func timestampLink(_ session: StreamSession, _ runtime: SessionRuntime) -> String? {
        guard let stream = session.stream else { return nil }
        // A live session's times count from when monitoring began, so they say nothing about the video.
        guard let spike = runtime.selectedSpike, session.mode == .vod else { return stream.link() }
        return stream.link(at: max(0, spike.time - settings.detection.preRoll))
    }

    func copyLink(_ session: StreamSession, _ runtime: SessionRuntime) {
        guard let link = timestampLink(session, runtime) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func exportSpikes(_ session: StreamSession, _ runtime: SessionRuntime, as format: ExportFormat) {
        guard let stream = session.stream, !runtime.spikes.isEmpty else {
            alertMessage = "There are no spikes to export yet."
            return
        }
        let detection = settings.detection
        let rows = SpikeExport.rows(spikes: runtime.spikes, transcript: runtime.transcript, stream: stream,
                                    settings: detection, timestamped: session.mode == .vod)
        let data: Data
        do {
            switch format {
            case .json: data = try SpikeExport.json(title: session.title, stream: stream, rows: rows, settings: detection)
            case .csv: data = Data(SpikeExport.csv(rows).utf8)
            }
        } catch {
            alertMessage = "Could not build the export: \(error.localizedDescription)"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle.prefix(60)) spikes.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            alertMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }
}
