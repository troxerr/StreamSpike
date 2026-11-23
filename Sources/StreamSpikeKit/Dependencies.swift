import Foundation

/// A command line tool or model file the app needs. GUI apps do not inherit the shell PATH,
/// so every one has an explicit path.
public enum Dependency: String, CaseIterable, Identifiable, Sendable {
    case ytDlp, ffmpeg, whisperCLI, chatDownloader, youtubeTranscriptAPI, whisperModel, twitchDl

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .whisperCLI: "whisper-cli"
        case .chatDownloader: "chat_downloader"
        case .youtubeTranscriptAPI: "youtube_transcript_api"
        case .whisperModel: "Whisper model"
        case .twitchDl: "twitch-dl"
        }
    }

    /// Optional tools are not reported as missing. They only add a fallback.
    public var isOptional: Bool { self == .twitchDl }

    public var purpose: String {
        switch self {
        case .ytDlp: "Stream details and audio download"
        case .ffmpeg: "Audio conversion to 16 kHz WAV chunks"
        case .whisperCLI: "Local speech to text"
        case .chatDownloader: "YouTube and Twitch chat"
        case .youtubeTranscriptAPI: "YouTube captions"
        case .whisperModel: "Speech model file (ggml)"
        case .twitchDl: "Optional. Twitch chat when chat_downloader fails"
        }
    }

    /// A model is a file to read, not a program to run.
    public var mustBeExecutable: Bool { self != .whisperModel }

    /// Default locations, best first. `~` is already expanded.
    public func candidates(home: String = Dependency.homePath) -> [String] {
        switch self {
        case .ytDlp: ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        case .ffmpeg: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        case .whisperCLI: ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        case .chatDownloader: [home + "/.local/bin/chat_downloader", "/opt/homebrew/bin/chat_downloader", "/usr/local/bin/chat_downloader"]
        case .youtubeTranscriptAPI: [home + "/.local/bin/youtube_transcript_api", "/opt/homebrew/bin/youtube_transcript_api", "/usr/local/bin/youtube_transcript_api"]
        case .whisperModel: [home + "/.local/share/whisper-models/ggml-base.en.bin"]
        case .twitchDl: [home + "/.local/bin/twitch-dl", "/opt/homebrew/bin/twitch-dl", "/usr/local/bin/twitch-dl"]
        }
    }

    /// The first default that exists, or the first default.
    public func defaultPath(home: String = Dependency.homePath) -> String {
        let list = candidates(home: home)
        return list.first { FileManager.default.fileExists(atPath: $0) } ?? list[0]
    }

    public static var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// A Terminal command that installs this one.
    public var installCommand: String {
        switch self {
        case .ytDlp: "brew install yt-dlp"
        case .ffmpeg: "brew install ffmpeg"
        case .whisperCLI: "brew install whisper-cpp"
        case .chatDownloader: "pipx install chat-downloader"
        case .twitchDl: "pipx install twitch-dl"
        case .youtubeTranscriptAPI: "pipx install youtube-transcript-api"
        case .whisperModel:
            "mkdir -p ~/.local/share/whisper-models && curl -L -o ~/.local/share/whisper-models/ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
        }
    }

    /// One command per line, with the Homebrew packages joined into one.
    public static func installCommand(for missing: [Dependency]) -> String {
        var lines: [String] = []
        let brew = missing.filter { $0.installCommand.hasPrefix("brew install ") }
            .map { String($0.installCommand.dropFirst("brew install ".count)) }
        if !brew.isEmpty { lines.append("brew install " + brew.joined(separator: " ")) }
        lines += missing.filter { !$0.installCommand.hasPrefix("brew install ") }.map(\.installCommand)
        return lines.joined(separator: "\n")
    }
}

public enum DependencyStatus: Sendable, Equatable {
    case ok
    case missing
    case notExecutable

    public var isOK: Bool { self == .ok }

    public var label: String {
        switch self {
        case .ok: "Found"
        case .missing: "Not found"
        case .notExecutable: "Not executable"
        }
    }

    public static func check(path: String, mustBeExecutable: Bool) -> DependencyStatus {
        let expanded = ToolPaths.expand(path)
        var isDirectory: ObjCBool = false
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing
        }
        if mustBeExecutable, !FileManager.default.isExecutableFile(atPath: expanded) { return .notExecutable }
        return .ok
    }
}

/// The chosen path for every dependency.
public struct ToolPaths: Sendable {
    public var paths: [Dependency: String]

    public init(paths: [Dependency: String] = [:]) {
        self.paths = paths
    }

    public func path(for dependency: Dependency) -> String {
        let chosen = paths[dependency]?.trimmingCharacters(in: .whitespaces) ?? ""
        return Self.expand(chosen.isEmpty ? dependency.defaultPath() : chosen)
    }

    public func status(of dependency: Dependency) -> DependencyStatus {
        .check(path: path(for: dependency), mustBeExecutable: dependency.mustBeExecutable)
    }

    public func missing() -> [Dependency] {
        Dependency.allCases.filter { !$0.isOptional && !status(of: $0).isOK }
    }

    /// Resolves a leading `~` with the real home folder.
    public static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return Dependency.homePath }
        if trimmed.hasPrefix("~/") { return Dependency.homePath + trimmed.dropFirst(1) }
        return trimmed
    }
}
