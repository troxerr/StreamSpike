import Foundation
import Observation
import StreamSpikeKit

/// What the screen shows for one stream: its chat, transcript, chart buckets, and spikes.
/// It fills while an analysis runs, so the chart grows as chat arrives.
@Observable
final class SessionRuntime {
    enum Phase: Equatable {
        case idle, loading, running, finished
        case failed(String)
    }

    var phase: Phase = .idle
    var chat: [ChatMessage] = []
    var transcript: [TranscriptSegment] = []
    var buckets: [ChatBucket] = []
    var spikes: [Spike] = []
    var selectedSpikeID: Int?
    /// Seconds. The stream's length when known, else as far as chat reaches.
    var duration: Double = 0

    var chatStatus = ""
    var chatFraction: Double?
    var transcriptStatus = ""
    var transcriptFraction: Double?
    var transcriptSource = ""
    var warnings: [String] = []

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var redetectTask: Task<Void, Never>?
    @ObservationIgnored private var chatIsSorted = true
    @ObservationIgnored private var dirty = false

    var isRunning: Bool { phase == .running }

    var selectedSpike: Spike? {
        spikes.first { $0.id == selectedSpikeID }
    }

    func reset() {
        chat = []
        transcript = []
        buckets = []
        spikes = []
        selectedSpikeID = nil
        chatStatus = ""
        chatFraction = nil
        transcriptStatus = ""
        transcriptFraction = nil
        transcriptSource = ""
        warnings = []
        chatIsSorted = true
        dirty = false
        phase = .idle
    }

    // MARK: Filling

    func append(chat batch: [ChatMessage]) {
        guard !batch.isEmpty else { return }
        if chatIsSorted {
            var previous = chat.last?.time ?? 0
            for message in batch {
                if message.time < previous { chatIsSorted = false; break }
                previous = message.time
            }
        }
        chat.append(contentsOf: batch)
        dirty = true
    }

    func append(transcript batch: [TranscriptSegment]) {
        transcript.append(contentsOf: batch)
        dirty = true
    }

    /// Where chat has reached, in seconds.
    var chatReach: Double {
        chat.last?.time ?? 0
    }

    // MARK: Reading

    func chatWindow(from: Double, to: Double) -> [ChatMessage] {
        guard chatIsSorted else { return chat.filter { $0.time >= from && $0.time <= to }.sorted { $0.time < $1.time } }
        var low = 0, high = chat.count
        while low < high {
            let mid = (low + high) / 2
            if chat[mid].time < from { low = mid + 1 } else { high = mid }
        }
        var result: [ChatMessage] = []
        var i = low
        while i < chat.count, chat[i].time <= to {
            result.append(chat[i])
            i += 1
        }
        return result
    }

    func transcriptWindow(from: Double, to: Double) -> [TranscriptSegment] {
        TranscriptPairing.window(transcript, from: from, to: to)
    }

    // MARK: Analysis

    /// Buckets chat and finds spikes off the main thread, then publishes the result.
    func recompute(settings: SpikeSettings, knownDuration: Double?) async {
        let chat = chat, transcript = transcript.sorted { $0.start < $1.start }
        let wanted = knownDuration ?? (chat.last?.time).map { $0 + 1 }
        dirty = false
        let analysis = await Task.detached(priority: .userInitiated) {
            let raw = SpikeDetector.analyze(messages: chat, settings: settings, duration: wanted)
            return SpikeAnalysis(buckets: raw.buckets,
                                 spikes: TranscriptPairing.attach(transcript, to: raw.spikes, settings: settings))
        }.value
        guard !Task.isCancelled else { return }
        publish(analysis, duration: wanted, bucketSeconds: Double(settings.bucketSeconds))
    }

    private func publish(_ analysis: SpikeAnalysis, duration wanted: Double?, bucketSeconds: Double) {
        buckets = analysis.buckets
        spikes = analysis.spikes
        duration = max(wanted ?? 0, Double(buckets.count) * bucketSeconds)
        if let selectedSpikeID, !spikes.contains(where: { $0.id == selectedSpikeID }) { self.selectedSpikeID = nil }
    }

    /// While an analysis runs: recompute about once a second when new data arrived.
    func refreshLoop(settings: @escaping @MainActor () -> SpikeSettings, knownDuration: Double?) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard dirty, !Task.isCancelled else { continue }
            await recompute(settings: settings(), knownDuration: knownDuration)
        }
    }

    // MARK: Loading a saved stream

    func load(session: StreamSession, settings: SpikeSettings) async {
        phase = .loading
        let chatData = session.chatData, transcriptData = session.transcriptData, spikesData = session.spikesData
        let decoded = await Task.detached {
            (SessionCodec.decode([ChatMessage].self, from: chatData) ?? [],
             SessionCodec.decode([TranscriptSegment].self, from: transcriptData) ?? [],
             SessionCodec.decode([Spike].self, from: spikesData) ?? [])
        }.value
        chat = decoded.0
        transcript = decoded.1
        spikes = decoded.2
        transcriptSource = session.transcriptSource
        chatIsSorted = true
        duration = session.duration
        // The saved spikes show at once. The chart buckets and fresh spikes follow.
        phase = .finished
        await recompute(settings: settings, knownDuration: session.duration > 0 ? session.duration : nil)
    }
}
