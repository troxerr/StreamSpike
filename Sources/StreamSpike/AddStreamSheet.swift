import SwiftUI
import StreamSpikeKit

struct AddStreamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var mode: StreamMode = .vod
    @State private var limitEnabled = false
    @State private var limitMinutes = 30

    private var parsed: StreamURL? { StreamURL.parse(urlText) }

    private var problem: String? {
        guard !urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let parsed else { return "That is not a YouTube or Twitch link." }
        if !parsed.supports(mode) {
            return mode == .vod ? "This is a channel link. Paste a link to a recording."
                : "This is a recording. Paste a channel link, or a link to a live YouTube video."
        }
        return nil
    }

    private var canStart: Bool { parsed != nil && problem == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Add Stream")
                .font(.title2.bold())

            Form {
                TextField("Link", text: $urlText, prompt: Text("youtube.com/watch?v=… or twitch.tv/videos/…"))
                    .onSubmit(start)
                Picker("Mode", selection: $mode) {
                    ForEach(StreamMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if mode == .vod {
                    Toggle("Only analyze the start", isOn: $limitEnabled)
                }
                if mode == .vod, limitEnabled {
                    Stepper("First \(limitMinutes) minutes", value: $limitMinutes, in: 5...720, step: 5)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            if mode == .live {
                Text("Chat and speech are timed from the moment you start. Leave it running, then press Stop Monitoring. It saves as you go.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Space.sm) {
                if let parsed, problem == nil {
                    PlatformBadge(platform: parsed.platform, size: 20)
                    Text("\(parsed.platform.displayName) \(parsed.kind == .vod ? "recording" : "channel")")
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Label(problem, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            DependencyBanner()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .live ? "Start Monitoring" : "Analyze", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .onChange(of: urlText) {
            if let parsed, parsed.platform != .youtube { mode = parsed.kind == .live ? .live : .vod }
        }
    }

    private func start() {
        guard canStart else { return }
        if model.addStream(urlText, mode: mode, limitMinutes: mode == .vod && limitEnabled ? limitMinutes : 0) != nil {
            dismiss()
        }
    }
}
