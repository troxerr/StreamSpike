import Foundation

public enum MetadataFetcher {
    /// Title, channel, and length from `yt-dlp --dump-single-json`.
    public static func fetch(ytDlp: String, url: String) async throws -> StreamMetadata {
        let result = try await ProcessRunner.runChecked(ytDlp, ["--dump-single-json", "--no-playlist", "--no-warnings", "--skip-download", url])
        return try parse(result.stdout)
    }

    public static func parse(_ json: String) throws -> StreamMetadata {
        struct Raw: Decodable {
            var title: String?
            var channel: String?
            var uploader: String?
            var duration: Double?
            var is_live: Bool?
        }
        guard let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw ToolError("yt-dlp returned details that could not be read.")
        }
        return StreamMetadata(title: raw.title ?? "Untitled stream", channel: raw.channel ?? raw.uploader ?? "",
                              duration: raw.duration, isLive: raw.is_live ?? false)
    }
}
