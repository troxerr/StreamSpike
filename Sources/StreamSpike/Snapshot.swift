import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/StreamSpike.app/Contents/MacOS/StreamSpike
/// writes <page>-light.png and <page>-dark.png for every page (welcome, stream, failed, add), and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=all,starred limits the pages. Add "settings" to include Settings.
/// Add APP_ACCENT=<id> to see the pages in another accent.
/// The pages snapshot mode walks through: nothing selected, a finished stream, a failed one.
enum SnapshotPage: String, CaseIterable {
    case welcome, stream, live, failed, add

    @MainActor
    func show(in model: AppModel) {
        let sessions = model.allSessions()
        model.showingAdd = self == .add
        switch self {
        case .welcome: model.selection = nil
        case .stream: model.selection = sessions.first { $0.status == .complete }?.uuid
        case .failed: model.selection = sessions.first { $0.status == .failed }?.uuid
        case .live:
            // A running live session has no task here, so fill its runtime by hand, as a minute-old monitor would look.
            guard let session = sessions.first(where: { $0.mode == .live }) else { break }
            model.selection = session.uuid
            let runtime = model.runtime(for: session)
            if runtime.chat.isEmpty {
                runtime.liveStart = Date().addingTimeInterval(-754)
                runtime.phase = .running
                runtime.append(chat: SeedData.makeChat(duration: 754, bursts: [(210, 70), (480, 120), (700, 90)], seed: 3))
                runtime.append(transcript: SeedData.makeTranscript(duration: 740))
                runtime.chatStatus = "Listening to #nightowlplays"
                runtime.transcriptStatus = "Transcribing live audio"
                runtime.transcriptSource = "Whisper (live)"
                Task { await runtime.recompute(settings: model.settings.detection, knownDuration: 754) }
            }
        case .add: break
        }
        if self == .stream, let session = sessions.first(where: { $0.status == .complete }) {
            // Select the strongest spike so the chart and the viewer show a selection.
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                model.existingRuntime(session.uuid).map { $0.selectedSpikeID = $0.spikes.first?.id }
            }
        }
    }
}

enum Snapshot {
    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        // Snapshots never run against the real database.
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        // APP_SNAPSHOT_NO_MODEL=1 points the Whisper model at a file that is not there, to see the download button.
        if env["APP_SNAPSHOT_NO_MODEL"] == "1" { AppSettings.shared.setPath("/tmp/StreamSpike-no-model/ggml-base.en.bin", for: .whisperModel) }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in SnapshotPage.allCases where only?.contains(page.rawValue) ?? true {
                    page.show(in: model)
                    try? await Task.sleep(for: .seconds(1.6))
                    capture(to: "\(dir)/\(page.rawValue)-\(mode).png")
                }
            }
            if only == nil || only?.contains("settings") == true {
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(0.8))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                }
            }
            model.showingAdd = false
            print("SNAPSHOT done \(dir)")
            // An open sheet refuses terminate, and the run would wait forever.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars and glass blank.
    private static func capture(to path: String, window: NSWindow? = nil) {
        // Another app can hide this one while snapshots run (computer use hides
        // apps it does not control). Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        // Active, like a window someone is using: real accent colors and focus rings.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}
