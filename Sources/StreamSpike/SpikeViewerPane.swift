import SwiftUI
import StreamSpikeKit

/// What the streamer said and what chat typed, from T-30 s to T+15 s around the selected spike.
struct SpikeViewerPane: View {
    @Environment(AppModel.self) private var model
    let session: StreamSession
    let runtime: SessionRuntime

    enum Filter: String, CaseIterable, Identifiable {
        case both = "Both", transcript = "Transcript", chat = "Chat"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        enum Kind { case transcript, chat, marker }
        let id: Int
        let kind: Kind
        let time: Double
        let author: String
        let text: String
    }

    private struct RowsKey: Equatable {
        var spikeID: Int?
        var filter: Filter
        var chatCount: Int
        var segmentCount: Int
        var window: Double
    }

    @State private var filter: Filter = .both
    @State private var rows: [Row] = []
    @State private var scrolledSpikeID: Int?

    private let maxChatRows = 4000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let spike = runtime.selectedSpike {
                list(for: spike)
            } else {
                ContentUnavailableView("Select a Spike", systemImage: "cursorarrow.click",
                                       description: Text("Pick a spike in the list or on the chart to read what was said and typed."))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.selectedSpike.map { "Spike at \(Timecode.string($0.time))" } ?? "Transcript and chat")
                        .font(.headline)
                    Text("T − \(Int(model.settings.detection.preRoll)) s to T + \(Int(model.settings.detection.postRoll)) s"
                         + (session.mode == .live ? " · times count from the start of monitoring" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Link", systemImage: "link") { model.copyLink(session, runtime) }
                    .help(linkHelp)
                    .disabled(session.stream == nil)
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Spikes as JSON…") { model.exportSpikes(session, runtime, as: .json) }
                    Button("Spikes as CSV…") { model.exportSpikes(session, runtime, as: .csv) }
                }
                .disabled(runtime.spikes.isEmpty)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var linkHelp: String {
        if session.mode == .live { return "Copy the stream link. Live times do not match the video." }
        return runtime.selectedSpike == nil
            ? "Copy the stream link (Shift-Command-C)"
            : "Copy a link that starts at the top of this window (Shift-Command-C)"
    }

    private func list(for spike: Spike) -> some View {
        ScrollViewReader { proxy in
            List(rows) { row in
                rowView(row, spike: spike)
                    .id(row.id)
                    .listRowBackground(row.kind == .transcript ? Palette.accent.opacity(0.08) : Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .task(id: RowsKey(spikeID: spike.id, filter: filter, chatCount: runtime.chat.count,
                              segmentCount: runtime.transcript.count,
                              window: model.settings.detection.preRoll + model.settings.detection.postRoll * 100)) {
                rows = buildRows(for: spike)
                // Move to the spike when it changes, not each time more chat arrives.
                guard scrolledSpikeID != spike.id else { return }
                scrolledSpikeID = spike.id
                try? await Task.sleep(for: .milliseconds(60))
                proxy.scrollTo(-1, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, spike: Spike) -> some View {
        switch row.kind {
        case .marker:
            HStack(spacing: Space.sm) {
                Rectangle().fill(Palette.accent).frame(height: 1)
                Text("Spike \(Timecode.string(spike.time))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.accentText)
                Rectangle().fill(Palette.accent).frame(height: 1)
            }
        case .transcript:
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                offsetLabel(row.time - spike.time)
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 16)
                Text(row.text)
            }
        case .chat:
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                offsetLabel(row.time - spike.time)
                Image(systemName: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(chatLine(row))
            }
        }
    }

    private func offsetLabel(_ seconds: Double) -> some View {
        Text(Timecode.relative(seconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
    }

    private func chatLine(_ row: Row) -> AttributedString {
        var name = AttributedString(row.author.isEmpty ? "" : row.author + "  ")
        name.font = .callout.weight(.semibold)
        name.foregroundColor = .secondary
        var text = AttributedString(row.text)
        text.font = .callout
        return name + text
    }

    private func buildRows(for spike: Spike) -> [Row] {
        let detection = model.settings.detection
        let from = spike.time - detection.preRoll
        let to = spike.time + detection.postRoll
        var built: [Row] = [Row(id: -1, kind: .marker, time: spike.time, author: "", text: "")]
        if filter != .chat {
            let segments = runtime.isRunning ? runtime.transcript.sorted { $0.start < $1.start } : runtime.transcript
            for (i, segment) in TranscriptPairing.window(segments, from: from, to: to).enumerated() {
                built.append(Row(id: 1_000_000 + i, kind: .transcript, time: segment.start, author: "", text: segment.text))
            }
        }
        if filter != .transcript {
            let messages = runtime.chatWindow(from: from, to: to)
            let step = max(1, messages.count / maxChatRows + 1)
            for (i, message) in messages.enumerated() where i % step == 0 {
                built.append(Row(id: 2_000_000 + i, kind: .chat, time: message.time, author: message.author, text: message.text))
            }
        }
        // Stable sort: at the same second the streamer's words come before chat.
        return built.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }
}
