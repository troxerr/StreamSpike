import AppKit
import Foundation
import StreamSpikeKit
import UserNotifications

extension Notification.Name {
    /// Posted when a notification is clicked. `userInfo` has the session's "uuid" and the spike's "spike" id.
    static let openSpikeFromNotification = Notification.Name("StreamSpike.openSpike")
}

/// Local notifications for spikes found while monitoring a live stream.
@MainActor
enum SpikeNotifier {
    /// Tests, snapshots and the self-test never ring.
    private static var available: Bool { !Store.isOverridden && Bundle.main.bundleIdentifier != nil }

    /// Asks once, when the first live run starts. The system remembers the answer.
    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// How many notifications this run decided to send, including the ones tests keep quiet. The self-test reads it.
    private(set) static var posted = 0

    static func post(spike: Spike, session: StreamSession) {
        posted += 1
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Chat spike at \(Timecode.string(spike.time)) · z \(String(format: "%.1f", spike.zScore))"
        content.subtitle = session.title.isEmpty ? session.channel : session.title
        var lines: [String] = []
        if !spike.topEmotes.isEmpty { lines.append(spike.topEmotes.map { "\($0.name) ×\($0.count)" }.joined(separator: "  ")) }
        if !spike.transcriptPreview.isEmpty { lines.append(spike.transcriptPreview) }
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        content.userInfo = ["uuid": session.uuid.uuidString, "spike": spike.id]
        let request = UNNotificationRequest(identifier: "spike-\(session.uuid.uuidString)-\(Int(spike.runStart))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
