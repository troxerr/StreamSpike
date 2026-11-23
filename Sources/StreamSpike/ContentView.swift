import SwiftData
import SwiftUI
import StreamSpikeKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 360)
        } detail: {
            DetailContainer()
        }
        .sheet(isPresented: $model.showingAdd) { AddStreamSheet() }
        .alert("StreamSpike", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task {
            SeedData.insertIfRequested(into: model)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \StreamSession.createdAt, order: .reverse) private var sessions: [StreamSession]

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .tag(session.uuid)
                    .contextMenu {
                        if session.status == .running {
                            Button("Stop") { model.cancel(session) }
                        } else {
                            Button(session.mode == .live ? "Monitor Again" : "Download Again") { model.restart(session) }
                        }
                        Button("Copy Link") { copy(session.urlString) }
                        Divider()
                        Button("Delete", role: .destructive) { model.remove(session) }
                    }
            }
        }
        .navigationTitle("Streams")
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView("No Streams", systemImage: "waveform",
                                       description: Text("Click + to add a YouTube or Twitch link."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Stream", systemImage: "plus") { model.newStream() }
                    .help("Add a stream (Command-N)")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: StreamSession

    var body: some View {
        HStack(spacing: Space.md) {
            PlatformBadge(platform: session.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch session.status {
            case .running:
                if session.mode == .live {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                } else {
                    ProgressView().controlSize(.small)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(session.statusDetail)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch session.status {
        case .queued: return "Queued"
        case .running:
            guard let runtime = model.existingRuntime(session.uuid) else { return "Starting" }
            if runtime.isLive { return "\(runtime.chat.count.formatted()) messages · \(runtime.spikes.count) spikes" }
            return runtime.chatStatus
        case .failed: return session.statusDetail.isEmpty ? "Failed" : session.statusDetail
        case .complete, .cancelled:
            let spikes = session.spikeCount == 1 ? "1 spike" : "\(session.spikeCount) spikes"
            let length = session.duration > 0 ? " · " + Timecode.string(session.duration) : ""
            return (session.status == .cancelled ? "Stopped · " : "") + (session.mode == .live ? "Live · " : "") + spikes + length
        }
    }
}

struct PlatformBadge: View {
    let platform: Platform
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                // A glyph on a saturated platform color, so a fixed white reads in light and dark.
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(platform.displayName)
    }

    private var color: Color {
        switch platform {
        case .youtube: .red
        case .twitch: .purple
        }
    }

    private var symbol: String {
        switch platform {
        case .youtube: "play.fill"
        case .twitch: "bubble.left.fill"
        }
    }
}

// MARK: - Detail

struct DetailContainer: View {
    @Environment(AppModel.self) private var model
    @Query private var sessions: [StreamSession]

    var body: some View {
        VStack(spacing: 0) {
            DependencyBanner()
            if let session = sessions.first(where: { $0.uuid == model.selection }) {
                StreamDetailView(session: session)
                    .id(session.uuid)
            } else {
                ContentUnavailableView {
                    Label("Find the moments chat lost it", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Add a VOD link to chart chat activity and read what the streamer said at each spike.")
                } actions: {
                    Button("Add Stream") { model.newStream() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
