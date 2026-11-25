import Foundation
import Observation
import StreamSpikeKit

/// What the Whisper model download looks like on screen. Shared by the Settings row and the missing-tools banner.
@MainActor
@Observable
final class ModelDownloadState {
    static let shared = ModelDownloadState()

    enum Phase: Equatable {
        case idle
        case downloading(Double?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isDownloading: Bool { if case .downloading = phase { true } else { false } }

    /// Downloads the model to the path Settings points at, then checks the tools again.
    func start(settings: AppSettings = .shared) {
        guard !isDownloading else { return }
        let destination = settings.toolPaths.path(for: .whisperModel)
        phase = .downloading(nil)
        task = Task {
            do {
                try await ModelDownloader.download(to: destination) { fraction in
                    Task { @MainActor in
                        guard self.isDownloading else { return }
                        self.phase = .downloading(fraction)
                    }
                }
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
            settings.refresh()
            task = nil
        }
    }

    var failureText: String? { if case .failed(let message) = phase { message } else { nil } }

    func cancel() {
        task?.cancel()
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }
}
