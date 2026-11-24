import Foundation

/// Decides which spike of a live run is worth a notification, and when.
/// A spike is announced once, after its run of busy buckets has ended: while chat is still climbing its
/// peak keeps moving, so announcing early would name the wrong moment and repeat itself.
public struct SpikeAnnouncer: Sendable {
    /// Spikes already handled, by the start of their run, which stays put as the run grows.
    private var handled = Set<Int>()
    private var lastAnnounced: Double?
    /// Fewest seconds between two notifications. A busy stream would otherwise ring every few seconds.
    public var minGap: Double

    public init(minGap: Double = 45) {
        self.minGap = minGap
    }

    /// The spike to announce now, if any. `elapsed` is how long monitoring has run.
    /// Every settled spike is marked handled, so one that was held back by `minGap` does not ring later, out of date.
    public mutating func next(spikes: [Spike], elapsed: Double, bucketSeconds: Double) -> Spike? {
        let settled = spikes.filter { $0.runEnd + bucketSeconds <= elapsed && !handled.contains(Int($0.runStart)) }
        guard !settled.isEmpty else { return nil }
        for spike in settled { handled.insert(Int(spike.runStart)) }
        if let lastAnnounced, elapsed - lastAnnounced < minGap { return nil }
        lastAnnounced = elapsed
        return settled.max { $0.zScore < $1.zScore }
    }
}
