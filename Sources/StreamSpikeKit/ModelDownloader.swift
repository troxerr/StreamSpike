import Foundation

/// Downloads the Whisper model file, so a person does not have to run curl in Terminal.
/// The file is checked before it replaces anything: a failed or half-finished download never leaves a bad model behind.
public enum ModelDownloader {
    /// The English base model: about 148 MB, fast, and good enough for a streamer's voice.
    public static let defaultURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
    /// Real ggml models are far larger. A smaller file is an error page or a cut-off transfer.
    public static let defaultMinimumBytes: Int64 = 50_000_000
    /// The first four bytes of a ggml model file ("ggml" read as a little-endian number).
    static let magic = Data("lmgg".utf8)

    /// Downloads `url` to `destination` and calls `progress` with 0 to 1 when the size is known.
    /// Cancelling the task stops the transfer and removes the partial file.
    public static func download(from url: URL = defaultURL, to destination: String,
                                minimumBytes: Int64 = defaultMinimumBytes,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let delegate = Transfer(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        let staged: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        try validate(staged, minimumBytes: minimumBytes)
        let target = URL(fileURLWithPath: ToolPaths.expand(destination))
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.moveItem(at: staged, to: target)
    }

    /// Throws unless the file looks like a whole ggml model.
    static func validate(_ file: URL, minimumBytes: Int64) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        guard size >= minimumBytes else {
            throw ToolError("The download was too small to be a Whisper model (\(size / 1000) KB). Try again, or install it with the command in Settings.")
        }
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4)
        }
        guard head == magic else {
            throw ToolError("The downloaded file is not a Whisper model. Try again, or install it with the command in Settings.")
        }
    }
}

/// One download. Reports progress, keeps the finished file, and resumes the waiting caller once.
private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var staged: URL?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<URL, Error>) {
        let ready = lock.withLock { () -> Result<URL, Error>? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    private func finish(_ result: Result<URL, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    /// The system deletes `location` when this returns, so the file moves to one this class owns.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("streamspike-model-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            lock.withLock { staged = keep }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let file = lock.withLock { staged }
        func discard() { if let file { try? FileManager.default.removeItem(at: file) } }
        if let error {
            discard()
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(ToolError("The download failed: \(error.localizedDescription)"))) }
            return
        }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
            discard()
            finish(.failure(ToolError("The download server answered \(http.statusCode). Try again later.")))
            return
        }
        if let file { finish(.success(file)) } else { finish(.failure(ToolError("The download did not produce a file."))) }
    }
}
