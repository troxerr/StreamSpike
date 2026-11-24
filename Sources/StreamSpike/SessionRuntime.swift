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
    /// Set while monitoring a live stream. Time zero of the chart.
    var liveStart: Date?

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var redetectTask: Task<Void, Never>?
    @ObservationIgnored private var chatIsSorted = true
    @ObservationIgnored private var dirty = false
    /// Called after every recompute. A live run uses it to notice new spikes.
    @ObservationIgnored var onPublish: (() -> Void)?
    @ObservationIgnored var announcer = SpikeAnnouncer()
    /// Chat bucketed so far. Live runs add only the new messages each second.
    @ObservationIgnored private var accumulator: SpikeDetector.Accumulator?

    var isRunning: Bool { phase == .running }
    var isLive: Bool { liveStart != nil }

    /// The most recent spike, which is what someone watching live wants first.
    var latestSpike: Spike? { spikes.max { $0.time < $1.time } }

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
        liveStart = nil
        chatIsSorted = true
        dirty = false
        accumulator = nil
        announcer = SpikeAnnouncer()
        onPublish = nil
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
        var accumulator = accumulator
        if let current = accumulator, !current.isValid(for: settings) || current.consumed > chat.count { accumulator = nil }
        let previous = accumulator
        let sorted = chatIsSorted
        let result = await Task.detached(priority: .userInitiated) {
            var acc = previous ?? SpikeDetector.Accumulator(settings: settings)
            acc.add(chat[acc.consumed...])
            let raw = SpikeDetector.detect(acc, settings: settings, duration: wanted) { from, to in
                sorted ? SessionRuntime.slice(chat, from: from, to: to) : chat.filter { $0.time >= from && $0.time < to }
            }
            let analysis = SpikeAnalysis(buckets: raw.buckets,
                                         spikes: TranscriptPairing.attach(transcript, to: raw.spikes, settings: settings))
            return (acc, analysis)
        }.value
        guard !Task.isCancelled else { return }
        self.accumulator = result.0
        publish(result.1, duration: wanted, bucketSeconds: Double(settings.bucketSeconds))
    }

    /// The messages in `from..<to` of a chat sorted by time.
    nonisolated static func slice(_ chat: [ChatMessage], from: Double, to: Double) -> [ChatMessage] {
        var low = 0, high = chat.count
        while low < high {
            let mid = (low + high) / 2
            if chat[mid].time < from { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < chat.count, chat[end].time < to { end += 1 }
        return Array(chat[low..<end])
    }

    private func publish(_ analysis: SpikeAnalysis, duration wanted: Double?, bucketSeconds: Double) {
        buckets = analysis.buckets
        spikes = analysis.spikes
        duration = max(wanted ?? 0, Double(buckets.count) * bucketSeconds)
        if let selectedSpikeID, !spikes.contains(where: { $0.id == selectedSpikeID }) { self.selectedSpikeID = nil }
        onPublish?()
    }

    /// While an analysis runs: recompute about once a second when new data arrived.
    /// `always` keeps the chart growing on a live stream even in a second with no new chat.
    func refreshLoop(settings: @escaping @MainActor () -> SpikeSettings, knownDuration: @escaping @MainActor () -> Double?,
                     always: Bool = false) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard dirty || always, !Task.isCancelled else { continue }
            await recompute(settings: settings(), knownDuration: knownDuration())
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
