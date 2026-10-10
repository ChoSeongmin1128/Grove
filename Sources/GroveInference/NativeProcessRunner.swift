import Darwin
import Foundation

public struct NativeProcessRunner: Sendable {
    public init() {}

    public func run(executable: URL, arguments: [String], directory: URL, log: URL,
                    standardOutput: URL? = nil) async throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InferenceError.missingExecutable(executable.lastPathComponent)
        }
        let box = ProcessLifetime(executable: executable, arguments: arguments, directory: directory, log: log,
                                  standardOutput: standardOutput)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try box.execute(); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { box.cancel() }
    }
}

private final class ProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private let directory: URL
    private let log: URL
    private let standardOutput: URL?
    private var process: Process?
    private var cancelled = false
    private var finished = false

    init(executable: URL, arguments: [String], directory: URL, log: URL, standardOutput: URL?) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.log = log
        self.standardOutput = standardOutput
    }

    func execute() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: log, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        var output = handle
        if let standardOutput {
            try Data().write(to: standardOutput, options: .withoutOverwriting)
            output = try FileHandle(forWritingTo: standardOutput)
        }
        defer { if output !== handle { try? output.close() } }
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = output
        task.standardError = handle
        task.standardInput = FileHandle.nullDevice
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            process = task
            try task.run()
        }
        task.waitUntilExit()
        let wasCancelled = lock.withLock {
            finished = true
            process = nil
            return cancelled
        }
        if wasCancelled { throw CancellationError() }
        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            throw InferenceError.workerFailed(task.terminationStatus)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
        // Only this object's still-running child can be killed; never target a process
        // name or a shared model server. All file output remains in the job directory.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if !self.finished, let process = self.process, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}
