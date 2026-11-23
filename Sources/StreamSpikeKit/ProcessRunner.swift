import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public struct ToolError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Runs a command line tool without blocking any thread. Cancelling the task stops the process.
public enum ProcessRunner {
    /// Folders a GUI app does not get from the shell, for tools that start other tools.
    public static var searchPath: String {
        let home = Dependency.homePath
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
    }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        captureStdout: Bool = true,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ToolError("\(executable) was not found or is not executable. Check the path in Settings.")
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = Collector(captureStdout: captureStdout)
        let outSplitter = LineSplitter { line in
            collector.addOut(line)
            onStdoutLine?(line)
        }
        let errSplitter = LineSplitter { line in
            collector.addErr(line)
            onStderrLine?(line)
        }
        let outReader = Task.detached { await drain(outPipe.fileHandleForReading, into: outSplitter) }
        let errReader = Task.detached { await drain(errPipe.fileHandleForReading, into: errSplitter) }

        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        do {
            try process.run()
        } catch {
            outReader.cancel()
            errReader.cancel()
            throw ToolError("Could not start \(executable): \(error.localizedDescription)")
        }

        let box = ProcessBox(process)
        var status: Int32 = -1
        await withTaskCancellationHandler {
            for await code in exits { status = code }
        } onCancel: {
            box.terminate()
        }
        await outReader.value
        await errReader.value
        try Task.checkCancellation()
        let (out, err) = collector.snapshot()
        return ProcessResult(status: status, stdout: out, stderr: err)
    }

    /// Like `run`, but a non-zero exit becomes an error that carries the tool's own message.
    @discardableResult
    public static func runChecked(
        _ executable: String,
        _ arguments: [String],
        captureStdout: Bool = true,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, captureStdout: captureStdout,
                                   onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
        guard result.status == 0 else {
            let name = (executable as NSString).lastPathComponent
            throw ToolError("\(name) failed (exit \(result.status)): \(tail(result.stderr.isEmpty ? result.stdout : result.stderr))")
        }
        return result
    }

    /// The last few lines of tool output, for an error message.
    public static func tail(_ text: String, lines: Int = 4) -> String {
        let all = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return all.suffix(lines).joined(separator: "\n")
    }
}

/// Reads a pipe in chunks until it closes. Much faster than iterating `FileHandle.bytes`,
/// which stalls on tools that print megabytes on one line (yt-dlp's JSON).
private func drain(_ handle: FileHandle, into splitter: LineSplitter) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                splitter.finish()
                continuation.resume()
            } else {
                splitter.add(data)
            }
        }
    }
}

/// Cuts a byte stream into lines at \n or \r.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func add(_ data: Data) {
        var lines: [String] = []
        lock.withLock {
            buffer.append(data)
            while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
        }
        lines.forEach(onLine)
    }

    func finish() {
        let rest = lock.withLock { () -> Data in
            defer { buffer = Data() }
            return buffer
        }
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private let captureStdout: Bool
    private var out: [String] = []
    private var err: [String] = []

    init(captureStdout: Bool) {
        self.captureStdout = captureStdout
    }

    func addOut(_ line: String) {
        guard captureStdout else { return }
        lock.withLock { out.append(line) }
    }

    func addErr(_ line: String) {
        lock.withLock {
            err.append(line)
            if err.count > 400 { err.removeFirst(200) }
        }
    }

    func snapshot() -> (String, String) {
        lock.withLock { (out.joined(separator: "\n"), err.joined(separator: "\n")) }
    }
}
