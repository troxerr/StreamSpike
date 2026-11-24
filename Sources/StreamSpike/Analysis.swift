import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import StreamSpikeKit

enum ExportFormat {
    case json, csv, markdown, clips, chapters

    var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        case .markdown: "md"
        case .clips, .chapters: "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .clips, .chapters: .plainText
        }
    }

    var nameSuffix: String {
        switch self {
        case .json, .csv, .markdown: "spikes"
        case .clips: "clips"
        case .chapters: "chapters"
        }
    }
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
        save()
        selection = session.uuid
        start(session)
        return session
    }

    /// Saves, and says so when the database refuses, instead of losing the change quietly.
    func save() {
        do {
            try context.save()
        } catch {
            alertMessage = "Could not save to the database: \(error.localizedDescription)"
        }
    }

    /// Sessions left `.running` by a crash or a force quit have no task behind them. Keep what was last saved.
    func recoverInterrupted() {
        var changed = false
        for session in allSessions() where session.status == .running || session.status == .queued {
            let hasData = compactChunks(of: session)
            if session.mode == .live {
                session.status = hasData ? .complete : .failed
                session.statusDetail = hasData ? "The app quit while monitoring. Kept what was saved." : "The app quit before anything was saved."
            } else {
                session.status = hasData ? .cancelled : .failed
                session.statusDetail = hasData ? "The app quit during the download. Kept what was saved." : "The app quit during the download."
            }
            changed = true
        }
        if changed { save() }
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
        if isLive {
            if settings.notifyLiveSpikes { SpikeNotifier.requestAuthorization() }
            runtime.onPublish = { [weak self, weak session] in
                guard let self, let session else { return }
                self.announceSpikes(session, runtime, startedAt: startedAt)
            }
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
            // A live run saves what is new every 30 s, so a crash loses little and a long run does not slow down.
            let autosave = Task { [weak self] in
                guard isLive else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    await self.autosave(session, runtime)
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

    /// Rings for a settled spike of a live run, unless the person is already looking at that stream.
    private func announceSpikes(_ session: StreamSession, _ runtime: SessionRuntime, startedAt: Date) {
        guard runtime.isRunning else { return }
        let size = Double(settings.detection.bucketSeconds)
        guard let spike = runtime.announcer.next(spikes: runtime.spikes, elapsed: Date().timeIntervalSince(startedAt), bucketSeconds: size),
              settings.notifyLiveSpikes else { return }
        if NSApp.isActive, selection == session.uuid { return }
        SpikeNotifier.post(spike: spike, session: session)
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
        // A download that stopped early looks like a quiet stretch. Say so when chat ends well before the video does.
        if let knownDuration, knownDuration > 0, !Task.isCancelled, runtime.chatReach < knownDuration * 0.7 {
            runtime.warnings.append("Chat ends at \(Timecode.string(runtime.chatReach)) but the video runs to \(Timecode.string(knownDuration)). The rest may be missing. Try Download Again.")
        }
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
        runtime.onPublish = nil
        let sorted = await Task.detached { [chat = runtime.chat] in chat.sorted { $0.time < $1.time } }.value
        runtime.chat = sorted
        if let failure, runtime.chat.isEmpty {
            runtime.phase = .failed(failure)
            session.status = .failed
            session.statusDetail = failure
            save()
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

    /// Saves only the chat that arrived since the last autosave, as one more chunk. The transcript and spikes are small
    /// and are saved whole. `persist` folds the chunks into `chatData` when the run ends.
    func autosave(_ session: StreamSession, _ runtime: SessionRuntime) async {
        let from = min(runtime.savedChatCount, runtime.chat.count)
        let fresh = Array(runtime.chat[from...])
        let transcript = runtime.transcript, spikes = runtime.spikes
        let blobs = await Task.detached {
            (fresh.isEmpty ? nil : SessionCodec.encode(fresh), SessionCodec.encode(transcript), SessionCodec.encode(spikes))
        }.value
        // The run may have ended while this was encoding. Its final save has already written everything.
        guard runtime.isRunning else { return }
        if let chunk = blobs.0 {
            context.insert(ChatChunk(sessionID: session.uuid, index: runtime.savedChunks, count: fresh.count, data: chunk))
            runtime.savedChunks += 1
            runtime.savedChatCount = from + fresh.count
        }
        session.transcriptData = blobs.1
        session.spikesData = blobs.2
        session.chatCount = runtime.savedChatCount
        session.segmentCount = transcript.count
        session.spikeCount = spikes.count
        session.transcriptSource = runtime.transcriptSource
        save()
    }

    func chunks(of id: UUID) -> [ChatChunk] {
        let found = (try? context.fetch(FetchDescriptor<ChatChunk>(predicate: #Predicate { $0.sessionID == id }))) ?? []
        return found.sorted { $0.index < $1.index }
    }

    func deleteChunks(of id: UUID) {
        for chunk in chunks(of: id) { context.delete(chunk) }
    }

    /// Folds a session's chunks into `chatData`, sorted by time, and removes them. Returns false when nothing was saved.
    @discardableResult
    func compactChunks(of session: StreamSession) -> Bool {
        let saved = chunks(of: session.uuid)
        guard !saved.isEmpty else { return session.chatData != nil }
        var chat = SessionCodec.decode([ChatMessage].self, from: session.chatData) ?? []
        for chunk in saved { chat += SessionCodec.decode([ChatMessage].self, from: chunk.data) ?? [] }
        chat.sort { $0.time < $1.time }
        session.chatData = SessionCodec.encode(chat)
        session.chatCount = chat.count
        for chunk in saved { context.delete(chunk) }
        return !chat.isEmpty
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
        deleteChunks(of: session.uuid)
        runtime.savedChatCount = chat.count
        runtime.savedChunks = 0
        save()
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
            self.save()
        }
    }

    // MARK: Sharing

    /// A link to the selected spike's synced window, or to the stream when no spike is selected.
    func timestampLink(_ session: StreamSession, _ runtime: SessionRuntime) -> String? {
        guard let stream = session.stream else { return nil }
        // A live session's times count from when monitoring began, so they say nothing about the video.
        guard let spike = runtime.selectedSpike, session.mode == .vod else { return stream.link() }
        return stream.link(at: max(0, spike.windowStart(settings.detection)))
    }

    func copyLink(_ session: StreamSession, _ runtime: SessionRuntime) {
        guard let link = timestampLink(session, runtime) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    /// Opens the selected spike's timestamped link, or the stream, in the default browser.
    func openInBrowser(_ session: StreamSession, _ runtime: SessionRuntime) {
        guard let link = timestampLink(session, runtime), let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Selects the spike after (or before) the selected one in time order.
    func stepSpike(_ runtime: SessionRuntime, forward: Bool) {
        let ordered = runtime.spikes.sorted { $0.time < $1.time }
        guard !ordered.isEmpty else { return }
        let current = runtime.selectedSpike.flatMap { selected in ordered.firstIndex { $0.id == selected.id } }
        let next: Int
        if let current { next = min(ordered.count - 1, max(0, current + (forward ? 1 : -1))) } else { next = forward ? 0 : ordered.count - 1 }
        runtime.selectedSpikeID = ordered[next].id
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
            case .markdown: data = Data(SpikeExport.markdown(title: session.title, rows: rows).utf8)
            case .clips: data = Data(SpikeExport.clipList(spikes: runtime.spikes, settings: detection).utf8)
            case .chapters: data = Data(SpikeExport.chapters(spikes: runtime.spikes, settings: detection).utf8)
            }
        } catch {
            alertMessage = "Could not build the export: \(error.localizedDescription)"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle.prefix(60)) \(format.nameSuffix).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            alertMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }
}
