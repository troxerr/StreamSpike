import Foundation

/// Pairs spikes with what the streamer said.
public enum TranscriptPairing {
    /// Segments that overlap `from...to`. `segments` must be sorted by start.
    public static func window(_ segments: [TranscriptSegment], from: Double, to: Double) -> [TranscriptSegment] {
        // Segments are short, but one can start before `from` and still reach into the window.
        let slack = 60.0
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start < from - slack { low = mid + 1 } else { high = mid }
        }
        var result: [TranscriptSegment] = []
        var i = low
        while i < segments.count, segments[i].start <= to {
            if segments[i].end >= from { result.append(segments[i]) }
            i += 1
        }
        return result
    }

    /// The spike's own window: `preRoll` before where the spike's run began, to `postRoll` after its peak T. For a one-bucket spike that is T - preRoll to T + postRoll.
    public static func window(_ segments: [TranscriptSegment], around spike: Spike, settings: SpikeSettings) -> [TranscriptSegment] {
        window(segments, from: spike.windowStart(settings), to: spike.time + settings.postRoll)
    }

    /// Fills in `transcriptPreview` for every spike.
    public static func attach(_ segments: [TranscriptSegment], to spikes: [Spike], settings: SpikeSettings) -> [Spike] {
        spikes.map { spike in
            var spike = spike
            spike.transcriptPreview = preview(segments, around: spike, settings: settings)
            return spike
        }
    }

    /// One line: what was said just before and at the peak, or the whole window when that is silent.
    public static func preview(_ segments: [TranscriptSegment], around spike: Spike, settings: SpikeSettings) -> String {
        var near = window(segments, from: spike.time - 15, to: spike.time + 5)
        if near.isEmpty { near = window(segments, around: spike, settings: settings) }
        let text = near.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > 140 else { return text }
        return String(text.prefix(140)) + "…"
    }
}
