import AppKit
import Foundation
import SwiftData
import StreamSpikeKit

enum SessionStatus: String {
    case queued, running, complete, failed, cancelled
}

/// One saved stream: its details, and the chat, transcript, and spikes as compressed blobs,
/// so a 200,000-message stream is one row and reopens at once.
@Model
final class StreamSession {
    var uuid: UUID = UUID()
    var urlString: String = ""
    var platformRaw: String = Platform.youtube.rawValue
    var modeRaw: String = StreamMode.vod.rawValue
    var title: String = ""
    var channel: String = ""
    var duration: Double = 0
    var createdAt: Date = Date.now
    var statusRaw: String = SessionStatus.queued.rawValue
    var statusDetail: String = ""
    /// 0 analyzes the whole stream.
    var limitSeconds: Double = 0
    var chatCount: Int = 0
    var segmentCount: Int = 0
    var spikeCount: Int = 0
    var transcriptSource: String = ""
    @Attribute(.externalStorage) var chatData: Data?
    @Attribute(.externalStorage) var transcriptData: Data?
    @Attribute(.externalStorage) var spikesData: Data?

    init(url: StreamURL, mode: StreamMode, limitSeconds: Double) {
        urlString = url.link()
        platformRaw = url.platform.rawValue
        modeRaw = mode.rawValue
        title = "\(url.platform.displayName) \(url.id)"
        self.limitSeconds = limitSeconds
    }

    var platform: Platform { Platform(rawValue: platformRaw) ?? .youtube }
    var mode: StreamMode { StreamMode(rawValue: modeRaw) ?? .vod }
    var stream: StreamURL? { StreamURL.parse(urlString) }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
}

/// A slice of a live run's chat, saved while monitoring so a long session never re-saves what it already wrote.
/// At the end of a run (or at the next launch, after a crash) the chunks fold back into the session's `chatData`.
@Model
final class ChatChunk {
    var sessionID: UUID = UUID()
    var index: Int = 0
    var count: Int = 0
    @Attribute(.externalStorage) var data: Data?

    init(sessionID: UUID, index: Int, count: Int, data: Data?) {
        self.sessionID = sessionID
        self.index = index
        self.count = count
        self.data = data
    }
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let container: ModelContainer
    let settings = AppSettings.shared

    /// The selected session's `uuid`.
    var selection: UUID?
    var showingAdd = false
    /// Shown in an alert: a failed export, a link that cannot be used.
    var alertMessage: String?
    private(set) var runtimes: [UUID: SessionRuntime] = [:]

    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .dependencies {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    init(container: ModelContainer) {
        self.container = container
        recoverInterrupted()
    }

    var context: ModelContext { container.mainContext }

    func allSessions() -> [StreamSession] {
        (try? context.fetch(FetchDescriptor<StreamSession>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    var selectedSession: StreamSession? {
        guard let selection else { return nil }
        return allSessions().first { $0.uuid == selection }
    }

    /// The runtime for a session, made on first use. Call from an action or `.task`, never from a view body.
    @discardableResult
    func runtime(for session: StreamSession) -> SessionRuntime {
        if let existing = runtimes[session.uuid] { return existing }
        let runtime = SessionRuntime()
        runtimes[session.uuid] = runtime
        return runtime
    }

    func existingRuntime(_ id: UUID?) -> SessionRuntime? {
        id.flatMap { runtimes[$0] }
    }

    /// Opens a saved stream: decodes its blobs off the main thread, then draws it.
    func prepare(_ session: StreamSession) async {
        let runtime = runtime(for: session)
        guard runtime.phase == .idle else { return }
        guard session.status == .complete || session.status == .cancelled || session.chatData != nil else { return }
        await runtime.load(session: session, settings: settings.detection)
    }

    func newStream() {
        showingAdd = true
    }

    func remove(_ session: StreamSession) {
        runtimes[session.uuid]?.task?.cancel()
        runtimes[session.uuid] = nil
        if selection == session.uuid { selection = nil }
        deleteChunks(of: session.uuid)
        context.delete(session)
        try? context.save()
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case dependencies, detection, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dependencies: "Dependencies"
        case .detection: "Detection"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .dependencies: "wrench.and.screwdriver"
        case .detection: "waveform.path.ecg"
        case .appearance: "paintpalette"
        }
    }
}
