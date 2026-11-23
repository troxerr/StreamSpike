import Foundation

/// A parsed YouTube or Twitch link.
public struct StreamURL: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A recording (or any YouTube video).
        case vod
        /// A channel that is, or may be, live now.
        case live
    }

    public var platform: Platform
    public var kind: Kind
    /// The video id, or the channel name for a live link.
    public var id: String
    /// What the person pasted, with a scheme added when it was missing.
    public var original: String

    public init(platform: Platform, kind: Kind, id: String, original: String) {
        self.platform = platform
        self.kind = kind
        self.id = id
        self.original = original
    }

    public func supports(_ mode: StreamMode) -> Bool {
        switch (platform, mode) {
        case (.youtube, _): true
        case (_, .vod): kind == .vod
        case (_, .live): kind == .live
        }
    }

    public static func parse(_ input: String) -> StreamURL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), var host = components.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = components.path.split(separator: "/").map(String.init)
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })

        switch host {
        case "youtu.be":
            guard let id = parts.first, isVideoID(id) else { return nil }
            return StreamURL(platform: .youtube, kind: .vod, id: id, original: text)
        case "youtube.com", "youtube-nocookie.com":
            if parts.first == "watch", let id = query["v"], isVideoID(id) {
                return StreamURL(platform: .youtube, kind: .vod, id: id, original: text)
            }
            if parts.count >= 2, ["live", "shorts", "embed", "v"].contains(parts[0]), isVideoID(parts[1]) {
                return StreamURL(platform: .youtube, kind: .vod, id: parts[1], original: text)
            }
            return nil
        case "twitch.tv":
            if parts.count >= 2, parts[0] == "videos", parts[1].allSatisfy(\.isNumber) {
                return StreamURL(platform: .twitch, kind: .vod, id: parts[1], original: text)
            }
            if parts.count >= 3, parts[1] == "video", parts[2].allSatisfy(\.isNumber) {
                return StreamURL(platform: .twitch, kind: .vod, id: parts[2], original: text)
            }
            if let channel = parts.first, parts.count == 1, !reservedTwitchPaths.contains(channel.lowercased()) {
                return StreamURL(platform: .twitch, kind: .live, id: channel.lowercased(), original: text)
            }
            return nil
        default:
            return nil
        }
    }

    /// A link that opens the stream at `seconds`.
    public func link(at seconds: Double? = nil) -> String {
        let total = max(0, Int((seconds ?? 0).rounded(.down)))
        switch (platform, kind) {
        case (.youtube, _):
            let base = "https://www.youtube.com/watch?v=\(id)"
            return seconds == nil ? base : base + "&t=\(total)s"
        case (.twitch, .vod):
            let base = "https://www.twitch.tv/videos/\(id)"
            guard seconds != nil else { return base }
            return base + "?t=\(total / 3600)h\((total % 3600) / 60)m\(total % 60)s"
        case (.twitch, .live):
            return "https://www.twitch.tv/\(id)"
        }
    }

    private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static let reservedTwitchPaths: Set<String> = [
        "directory", "videos", "settings", "downloads", "login", "signup", "turbo", "store", "jobs", "p",
    ]
}
