import AppKit
import SwiftData
import SwiftUI
import StreamSpikeKit
import UserNotifications

// StreamSpike
//   StreamSpike                      the app
//   APP_STORE=<file> StreamSpike     use another database (tests, experiments)
//   APP_SNAPSHOT=<dir> StreamSpike   save a PNG of every page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 StreamSpike           fill an empty /tmp store with sample streams (tools/snap.sh)
//   StreamSpike --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   SELFTEST_ONLINE=<url> StreamSpike --selftest    also run the real tools against one VOD link
//   APP_ACCENT=<id> StreamSpike      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 StreamSpike           draw the 8 pt grid and the layout probes over the window

@main
struct StreamSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(container: Store.makeContainer())

    var body: some Scene {
        Window("StreamSpike", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 1000, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: .openSpikeFromNotification)) { note in
                    guard let text = note.userInfo?["uuid"] as? String, let id = UUID(uuidString: text) else { return }
                    model.selection = id
                    if let spike = note.userInfo?["spike"] as? Int, let runtime = model.existingRuntime(id) { runtime.selectedSpikeID = spike }
                }
        }
        .modelContainer(model.container)
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Add Stream…") { model.newStream() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Stream") {
                Button("Copy Timestamped Link") {
                    if let session = model.selectedSession, let runtime = model.existingRuntime(session.uuid) {
                        model.copyLink(session, runtime)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Open in Browser") {
                    if let session = model.selectedSession, let runtime = model.existingRuntime(session.uuid) {
                        model.openInBrowser(session, runtime)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Next Spike") {
                    if let session = model.selectedSession, let runtime = model.existingRuntime(session.uuid) {
                        model.stepSpike(runtime, forward: true)
                    }
                }
                .keyboardShortcut("]")
                Button("Previous Spike") {
                    if let session = model.selectedSession, let runtime = model.existingRuntime(session.uuid) {
                        model.stepSpike(runtime, forward: false)
                    }
                }
                .keyboardShortcut("[")
                Divider()
                Button("Export Spikes as JSON…") { export(.json) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Export Spikes as CSV…") { export(.csv) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Spikes as Markdown…") { export(.markdown) }
                Button("Export Clip List…") { export(.clips) }
                Button("Export YouTube Chapters…") { export(.chapters) }
                Divider()
                Button("Download Again or Monitor Again") {
                    if let session = model.selectedSession { model.restart(session) }
                }
                .keyboardShortcut("r")
                Button("Stop") {
                    if let session = model.selectedSession { model.cancel(session) }
                }
                .keyboardShortcut(".")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }

    private func export(_ format: ExportFormat) {
        if let session = model.selectedSession, let runtime = model.existingRuntime(session.uuid) {
            model.exportSpikes(session, runtime, as: format)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Store.isOverridden { UNUserNotificationCenter.current().delegate = self }
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// A tool may have been installed while the app was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppSettings.shared.refresh()
    }

    /// A spike found while the app is in front of another stream still shows as a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification opens the app on that spike.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let uuid = info["uuid"] as? String, spike = info["spike"] as? Int
        await MainActor.run {
            NSApp.activate()
            var payload: [String: Any] = [:]
            if let uuid { payload["uuid"] = uuid }
            if let spike { payload["spike"] = spike }
            NotificationCenter.default.post(name: .openSpikeFromNotification, object: nil, userInfo: payload)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where the data lives: ~/Library/Application Support/StreamSpike/StreamSpike.store
enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "StreamSpike", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "StreamSpike.store")
    }

    static func makeContainer() -> ModelContainer {
        if let container = try? ModelContainer(for: StreamSession.self, ChatChunk.self, configurations: ModelConfiguration(url: url)) {
            return container
        }
        // The database would not open. Keep the broken file beside it for a person to inspect, and start a new one.
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            try? FileManager.default.moveItem(at: file, to: URL(fileURLWithPath: url.path + ".damaged-\(stamp)" + suffix))
        }
        do {
            return try ModelContainer(for: StreamSession.self, ChatChunk.self, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
        }
    }
}
