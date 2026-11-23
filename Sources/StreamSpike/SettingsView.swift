import AppKit
import SwiftUI
import StreamSpikeKit

/// The Settings window (Command-Comma). One tab per topic. Each tab is a grouped Form that sizes to
/// its content, so the window grows to fit and shows no scroll bar it does not need.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .dependencies: DependencySettings()
            case .detection: DetectionSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent(max: 680)
        .frame(width: tab == .dependencies ? 680 : 560)
    }
}

// MARK: - Dependencies

struct DependencySettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section {
            ForEach(Dependency.allCases) { dependency in
                DependencyRow(dependency: dependency)
            }
        } header: {
            Text("Tools and model")
        } footer: {
            Text("Apps do not inherit your shell PATH, so each tool needs its full path. Green means the file exists and can run.")
        }
        if !settings.missing.isEmpty {
            Section("Install what is missing") {
                Text(Dependency.installCommand(for: settings.missing))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Dependency.installCommand(for: settings.missing), forType: .string)
                    }
                    Button("Check Again") { settings.refresh() }
                }
            }
        }
    }
}

struct DependencyRow: View {
    let dependency: Dependency
    @Bindable private var settings = AppSettings.shared
    @State private var text = ""

    var body: some View {
        let status = settings.statuses[dependency] ?? .missing
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Image(systemName: status.isOK ? "checkmark.circle.fill" : (dependency.isOptional ? "minus.circle" : "xmark.circle.fill"))
                    .foregroundStyle(status.isOK ? Color.green : (dependency.isOptional ? Color.secondary : Color.red))
                    .accessibilityHidden(true)
                Text(dependency.title).font(.headline)
                Text(status.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…", action: choose)
                Button("Reset") {
                    settings.resetPath(for: dependency)
                    text = settings.displayPath(for: dependency)
                }
                .disabled(settings.overrides[dependency.rawValue] == nil)
            }
            TextField("Path", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
            Text(dependency.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs)
        .onAppear { text = settings.displayPath(for: dependency) }
        .onChange(of: text) { settings.setPath(text, for: dependency) }
        .accessibilityElement(children: .contain)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: ToolPaths.expand(text)).deletingLastPathComponent()
        panel.message = "Choose \(dependency.title)"
        if panel.runModal() == .OK, let url = panel.url { text = url.path }
    }
}

// MARK: - Detection

struct DetectionSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section {
            slider("Z-score threshold", value: $settings.detection.zThreshold, range: 1...6, step: 0.1, text: String(format: "%.1f", settings.detection.zThreshold))
            slider("Minimum messages per bucket", value: intBinding(\.minMessages), range: 1...100, step: 1, text: "\(settings.detection.minMessages)")
            slider("Bucket size", value: intBinding(\.bucketSeconds), range: 5...60, step: 5, text: "\(settings.detection.bucketSeconds) s")
            slider("Rolling baseline", value: minutesBinding, range: 1...15, step: 1, text: "\(settings.detection.baselineSeconds / 60) min")
        } header: {
            Text("Spike rule")
        } footer: {
            Text("A bucket is a spike when its Z-score is above the threshold and it holds at least the minimum number of messages. Z compares the bucket with the mean and deviation of the rolling baseline before it.")
        }

        Section("Transcript window") {
            Stepper("Before the spike: \(Int(settings.detection.preRoll)) s", value: $settings.detection.preRoll, in: 5...120, step: 5)
            Stepper("After the spike: \(Int(settings.detection.postRoll)) s", value: $settings.detection.postRoll, in: 5...60, step: 5)
        }

        Section {
            ForEach($settings.detection.hypeKeywords) { $keyword in
                HStack(spacing: Space.md) {
                    TextField("Keyword", text: $keyword.word)
                        .labelsHidden()
                        .font(.body.monospaced())
                        .frame(minWidth: 160)
                    Spacer(minLength: Space.sm)
                    Text("×\(keyword.weight, format: .number.precision(.fractionLength(2)))")
                        .font(.body.monospacedDigit())
                    Stepper("Weight", value: $keyword.weight, in: 1...3, step: 0.25)
                        .labelsHidden()
                    Button("Remove", systemImage: "minus.circle") {
                        settings.detection.hypeKeywords.removeAll { $0.id == keyword.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Keyword", systemImage: "plus") {
                    settings.detection.hypeKeywords.append(HypeKeyword(word: "", weight: 1.5))
                }
                Spacer()
                Button("Reset to Defaults") { settings.detection.hypeKeywords = HypeKeyword.defaults }
            }
        } header: {
            Text("Hype keywords and emotes")
        } footer: {
            Text("A message with one of these counts for its weight, so a wall of KEKW scores higher than the same number of plain messages. A keyword with no letters, like ???, matches anywhere in a message.")
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: Space.md) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 200)
                Text(text)
                    .font(.body.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<SpikeSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(settings.detection[keyPath: keyPath]) },
                set: { settings.detection[keyPath: keyPath] = Int($0.rounded()) })
    }

    private var minutesBinding: Binding<Double> {
        Binding(get: { Double(settings.detection.baselineSeconds) / 60 },
                set: { settings.detection.baselineSeconds = Int($0.rounded()) * 60 })
    }
}
