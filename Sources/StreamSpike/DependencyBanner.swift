import AppKit
import SwiftUI
import StreamSpikeKit

/// Shown while a tool or the Whisper model is missing. One click opens Settings or copies the install commands.
struct DependencyBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var copied = false

    var body: some View {
        let missing = model.settings.missing
        if !missing.isEmpty {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Missing: " + missing.map(\.title).joined(separator: ", "))
                        .font(.callout.weight(.semibold))
                    Text(Dependency.homebrewPath == nil && missing.contains { $0.installCommand.hasPrefix("brew ") }
                         ? "Homebrew is not installed. Install it from brew.sh first, then run the install command."
                         : "StreamSpike runs these tools to download chat and transcripts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                Button("Check Again") { model.settings.refresh() }
                Button("Open Settings") {
                    model.settingsTab = .dependencies
                    openSettings()
                }
                Button(copied ? "Copied" : "Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Dependency.installCommand(for: missing), forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            }
            .controlSize(.small)
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
