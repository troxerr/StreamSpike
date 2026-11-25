import AppKit
import SwiftUI
import StreamSpikeKit

/// Shown while a tool or the Whisper model is missing. One click opens Settings or copies the install commands.
struct DependencyBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var copied = false
    @Bindable private var download = ModelDownloadState.shared

    var body: some View {
        let missing = model.settings.missing
        if !missing.isEmpty {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Missing: " + missing.map(\.title).joined(separator: ", "))
                        .font(.callout.weight(.semibold))
                    Text(download.failureText ?? (Dependency.homebrewPath == nil && missing.contains { $0.installCommand.hasPrefix("brew ") }
                         ? "Homebrew is not installed. Install it from brew.sh first, then run the install command."
                         : "StreamSpike runs these tools to download chat and transcripts."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                if missing.contains(.whisperModel) { ModelDownloadButton() }
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

/// Downloads the Whisper model: a button, then a progress bar with Cancel, then the reason if it failed.
struct ModelDownloadButton: View {
    @Bindable private var download = ModelDownloadState.shared

    var body: some View {
        switch download.phase {
        case .idle:
            Button("Download Model", systemImage: "arrow.down.circle") { download.start() }
        case .failed:
            Button("Try Download Again", systemImage: "arrow.clockwise") { download.start() }
        case .downloading(let fraction):
            HStack(spacing: Space.sm) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 96)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { download.cancel() }
            }
        }
    }
}
