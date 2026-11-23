import SwiftUI
import StreamSpikeKit

/// Chart on top, spike list bottom left, synced transcript and chat bottom right.
struct StreamDetailView: View {
    @Environment(AppModel.self) private var model
    let session: StreamSession

    var body: some View {
        Group {
            if let runtime = model.existingRuntime(session.uuid) {
                content(runtime)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.uuid) { await model.prepare(session) }
        .navigationTitle(session.title)
        .navigationSubtitle(subtitle)
        .onChange(of: model.settings.detection) { model.redetect(session) }
    }

    private var subtitle: String {
        [session.platform.displayName, session.channel, session.mode == .live ? "Live" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ runtime: SessionRuntime) -> some View {
        VStack(spacing: 0) {
            if runtime.isRunning {
                ProgressStrip(runtime: runtime, stop: { model.cancel(session) })
                Divider()
            }
            if let warning = runtime.warnings.first, !runtime.isRunning {
                WarningBar(text: warning)
            }
            if case .failed(let message) = runtime.phase {
                ContentUnavailableView {
                    Label("Could not analyze this stream", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { model.start(session) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    ChartPane(runtime: runtime)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 200, idealHeight: 300)
                    HSplitView {
                        SpikeListPane(runtime: runtime)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .frame(minWidth: 320, idealWidth: 440)
                        SpikeViewerPane(session: session, runtime: runtime)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .frame(minWidth: 360, idealWidth: 480)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 240, idealHeight: 360)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                if runtime.isRunning {
                    Button(session.mode == .live ? "Stop Monitoring" : "Stop", systemImage: "stop.fill") { model.cancel(session) }
                        .help("Stop and keep what arrived")
                } else {
                    Button(session.mode == .live ? "Monitor Again" : "Download Again", systemImage: "arrow.clockwise") { model.restart(session) }
                        .help(session.mode == .live ? "Start a new live session for this stream (Command-R)"
                              : "Download chat and transcript again (Command-R)")
                }
            }
        }
    }
}

/// What the two ingestion jobs are doing right now. A live run also shows how long it has run and its latest spike.
struct ProgressStrip: View {
    let runtime: SessionRuntime
    let stop: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            if let start = runtime.liveStart { liveHeader(start: start) }
            HStack(alignment: .center, spacing: Space.lg) {
                VStack(spacing: Space.xs) {
                    line("Chat", status: runtime.chatStatus, fraction: runtime.isLive ? nil : runtime.chatFraction)
                    line("Transcript", status: transcriptStatus, fraction: runtime.isLive ? nil : runtime.transcriptFraction)
                }
                Button("Stop", action: stop)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }

    private func liveHeader(start: Date) -> some View {
        HStack(spacing: Space.sm) {
            Text("LIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 2)
                .background(Color.red, in: Capsule())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Timecode.string(context.date.timeIntervalSince(start)))
                    .font(.callout.monospacedDigit())
            }
            Text("\(runtime.chat.count.formatted()) messages")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let latest = runtime.latestSpike {
                Button("Latest spike \(Timecode.string(latest.time)) · z \(String(format: "%.1f", latest.zScore))") {
                    runtime.selectedSpikeID = latest.id
                }
                .controlSize(.small)
            } else {
                Text("No spikes yet").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptStatus: String {
        runtime.transcriptSource.isEmpty ? runtime.transcriptStatus : "\(runtime.transcriptSource): \(runtime.transcriptStatus)"
    }

    private func line(_ label: String, status: String, fraction: Double?) -> some View {
        HStack(spacing: Space.md) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 72, alignment: .leading)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView(value: nil as Double?)
            }
            Text(status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 240, alignment: .trailing)
        }
    }
}

struct WarningBar: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
    }
}
