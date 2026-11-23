import SwiftUI
import StreamSpikeKit

/// Spikes, strongest first. Selecting one highlights it on the chart and moves the viewer to it.
struct SpikeListPane: View {
    let runtime: SessionRuntime

    var body: some View {
        @Bindable var runtime = runtime
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("Spikes").font(.headline)
                Text("\(runtime.spikes.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("ranked by Z-score").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $runtime.selectedSpikeID) {
                    ForEach(Array(runtime.spikes.enumerated()), id: \.element.id) { index, spike in
                        SpikeRow(rank: index + 1, spike: spike)
                            .tag(spike.id)
                    }
                }
                .onChange(of: runtime.selectedSpikeID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .overlay {
                    if runtime.spikes.isEmpty {
                        ContentUnavailableView(
                            runtime.isRunning ? "Looking for spikes" : "No spikes",
                            systemImage: "waveform.path.ecg",
                            description: Text(runtime.isRunning ? "" : "Lower the Z-score threshold or message floor in Settings to find quieter moments."))
                    }
                }
            }
        }
    }
}

struct SpikeRow: View {
    let rank: Int
    let spike: Spike

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text("#\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(Timecode.string(spike.time))
                        .font(.headline.monospacedDigit())
                    Text("z \(spike.zScore, format: .number.precision(.fractionLength(1)))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.15), in: Capsule())
                    Text("\(spike.peakPerSecond, format: .number.precision(.fractionLength(1))) msg/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !spike.topEmotes.isEmpty {
                    Text(spike.topEmotes.map { "\($0.name) ×\($0.count)" }.joined(separator: "  "))
                        .font(.callout)
                        .lineLimit(1)
                }
                Text(spike.transcriptPreview.isEmpty ? "No transcript near this moment" : spike.transcriptPreview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}
