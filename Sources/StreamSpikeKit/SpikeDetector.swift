import Foundation

/// Chat activity in one time bucket.
public struct ChatBucket: Sendable, Hashable, Codable, Identifiable {
    public var index: Int
    /// Seconds from the start of the video.
    public var start: Double
    /// Messages in the bucket.
    public var count: Int
    /// Messages weighted by hype keywords. The Z-score is computed on this.
    public var score: Double
    /// Z-score against the rolling baseline before this bucket. 0 until there is enough history.
    public var z: Double

    public var id: Int { index }
}

public struct EmoteCount: Sendable, Hashable, Codable {
    public var name: String
    public var count: Int
}

public struct Spike: Sendable, Hashable, Codable, Identifiable {
    /// Index of the peak bucket. Unique within one analysis.
    public var id: Int
    /// Start of the peak bucket, in seconds. This is the spike's timestamp T.
    public var time: Double
    public var zScore: Double
    /// Messages in the peak bucket.
    public var messageCount: Int
    public var peakPerSecond: Double
    public var topEmotes: [EmoteCount]
    /// The first and last-end of the run of buckets this spike merged.
    public var runStart: Double
    public var runEnd: Double
    /// One line of what the streamer said around T. Filled in by `TranscriptPairing`.
    public var transcriptPreview: String
}

public struct SpikeAnalysis: Sendable {
    public var buckets: [ChatBucket]
    /// Strongest first.
    public var spikes: [Spike]

    public init(buckets: [ChatBucket], spikes: [Spike]) {
        self.buckets = buckets
        self.spikes = spikes
    }

    public static let empty = SpikeAnalysis(buckets: [], spikes: [])
}

public enum SpikeDetector {
    /// Floor for the deviation, so a silent chat that wakes up does not divide by zero.
    static let sigmaFloor = 1.0

    /// Buckets chat, scores each bucket against the rolling baseline before it, and flags spikes.
    /// `duration` pads the end with empty buckets so a quiet finish still shows on the chart.
    public static func analyze(messages: [ChatMessage], settings: SpikeSettings, duration: Double? = nil) -> SpikeAnalysis {
        let size = Double(max(1, settings.bucketSeconds))
        let matcher = KeywordMatcher(settings.hypeKeywords)

        var counts: [Int] = []
        var scores: [Double] = []
        for message in messages where message.time >= 0 {
            let index = Int(message.time / size)
            if index >= counts.count {
                counts.append(contentsOf: repeatElement(0, count: index - counts.count + 1))
                scores.append(contentsOf: repeatElement(0, count: index - scores.count + 1))
            }
            counts[index] += 1
            scores[index] += matcher.weight(of: message.text)
        }
        let wanted = duration.map { Int(($0 / size).rounded(.up)) } ?? 0
        if wanted > counts.count {
            counts.append(contentsOf: repeatElement(0, count: wanted - counts.count))
            scores.append(contentsOf: repeatElement(0, count: wanted - scores.count))
        }
        guard !counts.isEmpty else { return .empty }

        let baseline = max(2, Int(Double(settings.baselineSeconds) / size))
        let minHistory = min(baseline, 6)
        var z = [Double](repeating: 0, count: counts.count)
        var sum = 0.0, sumSquares = 0.0
        for i in 0..<counts.count {
            let history = min(i, baseline)
            if history >= minHistory {
                let mean = sum / Double(history)
                let variance = max(0, sumSquares / Double(history) - mean * mean)
                z[i] = (scores[i] - mean) / max(variance.squareRoot(), sigmaFloor)
            }
            sum += scores[i]
            sumSquares += scores[i] * scores[i]
            if i >= baseline {
                let old = scores[i - baseline]
                sum -= old
                sumSquares -= old * old
            }
        }

        let buckets = counts.indices.map {
            ChatBucket(index: $0, start: Double($0) * size, count: counts[$0], score: scores[$0], z: z[$0])
        }
        let flagged = buckets.map { $0.z > settings.zThreshold && $0.count >= settings.minMessages }

        // Merge neighbouring flagged buckets into one spike that peaks at the highest Z.
        var runs: [(first: Int, last: Int, peak: Int)] = []
        var i = 0
        while i < flagged.count {
            guard flagged[i] else { i += 1; continue }
            var last = i, peak = i
            while last + 1 < flagged.count, flagged[last + 1] {
                last += 1
                if buckets[last].z > buckets[peak].z { peak = last }
            }
            runs.append((i, last, peak))
            i = last + 1
        }

        var runOfBucket: [Int: Int] = [:]
        for (r, run) in runs.enumerated() { for b in run.first...run.last { runOfBucket[b] = r } }
        var emoteCounts = [[String: Int]](repeating: [:], count: runs.count)
        if !runs.isEmpty {
            for message in messages where message.time >= 0 {
                guard let r = runOfBucket[Int(message.time / size)] else { continue }
                for name in matcher.emotes(in: message.text) { emoteCounts[r][name, default: 0] += 1 }
            }
        }

        let spikes = runs.enumerated().map { r, run -> Spike in
            let peak = buckets[run.peak]
            let top = emoteCounts[r]
                .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .prefix(3)
                .map { EmoteCount(name: $0.key, count: $0.value) }
            return Spike(id: peak.index, time: peak.start, zScore: peak.z, messageCount: peak.count,
                         peakPerSecond: Double(peak.count) / size, topEmotes: Array(top),
                         runStart: buckets[run.first].start, runEnd: buckets[run.last].start + size,
                         transcriptPreview: "")
        }
        return SpikeAnalysis(buckets: buckets, spikes: spikes.sorted { $0.zScore > $1.zScore })
    }
}

/// Finds hype keywords and emote-like words in chat text.
struct KeywordMatcher {
    private var weights: [String: Double] = [:]
    private var names: [String: String] = [:]
    /// Keywords with no letters or digits, like `???`. They match anywhere in the text.
    private var symbols: [(text: String, weight: Double, name: String)] = []

    init(_ keywords: [HypeKeyword]) {
        for keyword in keywords {
            let word = keyword.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            if word.contains(where: { $0.isLetter || $0.isNumber }) {
                let key = word.lowercased()
                weights[key] = max(weights[key] ?? 1, keyword.weight)
                names[key] = word
            } else {
                symbols.append((word, keyword.weight, word))
            }
        }
    }

    /// 1.0 for a plain message, or the strongest keyword weight in it.
    func weight(of text: String) -> Double {
        var best = 1.0
        for token in tokens(text) {
            if let w = weights[token.lowercased()] { best = max(best, w) }
        }
        for symbol in symbols where text.contains(symbol.text) { best = max(best, symbol.weight) }
        return best
    }

    /// Hype keywords and emote-like words in the text, once per occurrence.
    func emotes(in text: String) -> [String] {
        var found: [String] = []
        for token in tokens(text) {
            if let name = names[token.lowercased()] {
                found.append(name)
            } else if Self.isEmoteLike(token) {
                found.append(token)
            }
        }
        for symbol in symbols where text.contains(symbol.text) { found.append(symbol.name) }
        return found
    }

    private func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let trimmed = raw.drop { $0.isPunctuation && $0 != ":" }.reversed().drop { $0.isPunctuation && $0 != ":" }.reversed()
            return trimmed.isEmpty ? nil : String(trimmed)
        }
    }

    /// `KEKW`, `PogChamp`, `monkaS`, and `:smile:`, but not ordinary words.
    static func isEmoteLike(_ token: String) -> Bool {
        if token.count > 2, token.hasPrefix(":"), token.hasSuffix(":") { return true }
        guard token.count >= 3, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let hasLower = token.contains { $0.isLowercase }
        let hasLetter = token.contains { $0.isLetter }
        let innerUpper = token.dropFirst().contains { $0.isUppercase }
        return (!hasLower && hasLetter) || (hasLower && innerUpper)
    }
}
