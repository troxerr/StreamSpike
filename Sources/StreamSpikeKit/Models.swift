import Foundation

public enum Platform: String, Codable, CaseIterable, Sendable {
    case youtube, twitch

    public var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .twitch: "Twitch"
        }
    }
}

public enum StreamMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case vod, live

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vod: "VOD Analysis"
        case .live: "Live Monitor"
        }
    }
}

/// One chat line. `time` is seconds from the start of the video.
/// Encodes as `[time, author, text]` so a few hundred thousand lines stay small on disk.
public struct ChatMessage: Sendable, Hashable, Codable {
    public var time: Double
    public var author: String
    public var text: String

    public init(time: Double, author: String, text: String) {
        self.time = time
        self.author = author
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        time = try container.decode(Double.self)
        author = try container.decode(String.self)
        text = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(time)
        try container.encode(author)
        try container.encode(text)
    }
}

/// One caption or Whisper segment, in seconds from the start of the video.
public struct TranscriptSegment: Sendable, Hashable, Codable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct StreamMetadata: Sendable, Hashable, Codable {
    public var title: String
    public var channel: String
    public var duration: Double?
    public var isLive: Bool

    public init(title: String, channel: String, duration: Double?, isLive: Bool) {
        self.title = title
        self.channel = channel
        self.duration = duration
        self.isLive = isLive
    }
}

/// Seconds as `1:02:03` or `2:03`.
public enum Timecode {
    public static func string(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `+0:12` or `-0:30`, for offsets from a spike.
    public static func relative(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "-" : "+"
        return sign + string(abs(seconds))
    }
}
