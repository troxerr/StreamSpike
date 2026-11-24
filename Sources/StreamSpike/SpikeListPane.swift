import SwiftUI
import StreamSpikeKit

/// Spikes, strongest first. Selecting one highlights it on the chart and moves the viewer to it.
struct SpikeListPane: View {
    let runtime: SessionRuntime
    @State private var query = ""
    @State private var byTime = false

    /// Rank is always by Z-score, so a row keeps its number whatever the sort or the search.
    private var rows: [(rank: Int, spike: Spike)] {
        var ranked = runtime.spikes.enumerated().map { (rank: $0.offset + 1, spike: $0.element) }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            ranked = ranked.filter { row in
                row.spike.transcriptPreview.lowercased().contains(needle)
                    || row.spike.topEmotes.contains { $0.name.lowercased().contains(needle) }
                    || Timecode.string(row.spike.time).contains(needle)
            }
        }
        if byTime { ranked.sort { $0.spike.time < $1.spike.time } }
        return ranked
    }

    var body: some View {
        @Bindable var runtime = runtime
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("Spikes").font(.headline)
                Text("\(runtime.spikes.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $byTime) {
                    Text("Z-score").tag(false)
                    Text("Time").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Sort spikes by Z-score or by time")
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $runtime.selectedSpikeID) {
                    ForEach(rows, id: \.spike.id) { row in
                        SpikeRow(rank: row.rank, spike: row.spike)
                            .tag(row.spike.id)
                    }
                }
                .onChange(of: runtime.selectedSpikeID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search spikes")
                .overlay {
                    if !runtime.spikes.isEmpty && rows.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if runtime.spikes.isEmpty {
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
