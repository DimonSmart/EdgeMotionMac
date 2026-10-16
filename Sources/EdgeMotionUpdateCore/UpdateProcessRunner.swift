import Foundation

public struct UpdateCommandResult: Equatable {
    public let exitCode: Int32
    public let output: String
    public let error: String

    public init(exitCode: Int32, output: String = "", error: String = "") {
        self.exitCode = exitCode
        self.output = output
        self.error = error
    }
}

public protocol UpdateCommandRunning {
    func run(_ executable: String, _ arguments: [String], cancellable: Bool) async -> UpdateCommandResult
}

public struct LocalUpdateCommandRunner: UpdateCommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], cancellable: Bool) async -> UpdateCommandResult {
        let operation = RunningCommand()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: operation.execute(executable, arguments))
                }
            }
        }, onCancel: {
            if cancellable { operation.cancel() }
        })
    }
}

private final class RunningCommand {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running = running, running.isRunning { running.terminate() }
    }

    func execute(_ executable: String, _ args: [String]) -> UpdateCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edgemotion-update-\(UUID().uuidString)")
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = FileManager.default.createFile(atPath: stdout.path, contents: nil)
            _ = FileManager.default.createFile(atPath: stderr.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: stdout)
            let errHandle = try FileHandle(forWritingTo: stderr)
            defer { outHandle.closeFile(); errHandle.closeFile() }
            process.standardOutput = outHandle
            process.standardError = errHandle
            lock.lock()
            if cancelled {
                lock.unlock()
                return UpdateCommandResult(exitCode: -1, error: "Cancelled")
            }
            self.process = process
            do {
                try process.run()
            } catch {
                self.process = nil
                lock.unlock()
                return UpdateCommandResult(exitCode: -1, error: error.localizedDescription)
            }
            lock.unlock()
            process.waitUntilExit()
            lock.lock()
            self.process = nil
            lock.unlock()
            return UpdateCommandResult(
                exitCode: process.terminationStatus,
                output: (try? String(contentsOf: stdout, encoding: .utf8)) ?? "",
                error: (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
        } catch {
            return UpdateCommandResult(exitCode: -1, error: error.localizedDescription)
        }
    }
}
