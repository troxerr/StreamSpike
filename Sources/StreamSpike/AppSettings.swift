import Foundation
import Observation
import StreamSpikeKit

/// Tool paths and spike-detection settings. Saved in UserDefaults, except in test and snapshot runs.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let persists = !Store.isOverridden
    private static let detectionKey = "detection.settings"
    private static let pathsKey = "tools.paths"
    private static let notifyKey = "notify.liveSpikes"

    var detection: SpikeSettings {
        didSet {
            guard persists, let data = try? JSONEncoder().encode(detection) else { return }
            UserDefaults.standard.set(data, forKey: Self.detectionKey)
        }
    }

    /// Ring a notification when a live stream has a spike. Saved like the other settings.
    var notifyLiveSpikes: Bool = true {
        didSet { if persists { UserDefaults.standard.set(notifyLiveSpikes, forKey: Self.notifyKey) } }
    }

    /// Paths the person typed. A dependency with no entry uses its default.
    private(set) var overrides: [String: String]
    private(set) var statuses: [Dependency: DependencyStatus] = [:]

    private init() {
        let defaults = UserDefaults.standard
        if !Store.isOverridden,
           let data = defaults.data(forKey: Self.detectionKey),
           let saved = try? JSONDecoder().decode(SpikeSettings.self, from: data) {
            detection = saved
        } else {
            detection = SpikeSettings()
        }
        if !Store.isOverridden, defaults.object(forKey: Self.notifyKey) != nil {
            notifyLiveSpikes = defaults.bool(forKey: Self.notifyKey)
        }
        overrides = Store.isOverridden ? [:] : (defaults.dictionary(forKey: Self.pathsKey) as? [String: String] ?? [:])
        refresh()
    }

    var toolPaths: ToolPaths {
        var paths: [Dependency: String] = [:]
        for (key, value) in overrides { if let dependency = Dependency(rawValue: key) { paths[dependency] = value } }
        return ToolPaths(paths: paths)
    }

    var missing: [Dependency] {
        Dependency.allCases.filter { !$0.isOptional && statuses[$0]?.isOK == false }
    }

    /// What the Settings field shows: the typed path, or the default.
    func displayPath(for dependency: Dependency) -> String {
        overrides[dependency.rawValue] ?? dependency.defaultPath()
    }

    func setPath(_ path: String, for dependency: Dependency) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == dependency.defaultPath() {
            overrides[dependency.rawValue] = nil
        } else {
            overrides[dependency.rawValue] = trimmed
        }
        if persists { UserDefaults.standard.set(overrides, forKey: Self.pathsKey) }
        refresh()
    }

    func resetPath(for dependency: Dependency) {
        setPath("", for: dependency)
    }

    /// Checks every path again. Cheap: one file lookup each.
    func refresh() {
        let paths = toolPaths
        statuses = Dictionary(uniqueKeysWithValues: Dependency.allCases.map { ($0, paths.status(of: $0)) })
    }
}
