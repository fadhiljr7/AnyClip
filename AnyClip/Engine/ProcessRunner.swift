//
//  ProcessRunner.swift
//  AnyClip
//

import Foundation

nonisolated struct ProcessFailure: LocalizedError {
    var tool: String
    var status: Int32
    var output: String

    var errorDescription: String? {
        let lines = output.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains("ERROR") || $0.lowercased().contains("error") }
        let detail = (errors.last ?? lines.last ?? "").replacing("ERROR: ", with: "")
        return String(localized: "\(tool) stopped (\(status)). \(detail)")
    }
}

nonisolated enum ProcessRunner {
    /// How long a tool gets to stop after being asked before it is killed.
    private static let terminationGrace: Duration = .seconds(3)
    /// A helper the tool left behind can keep its output open after the tool itself has ended; don't wait for it.
    private static let outputDrainLimit: Duration = .seconds(2)

    /// Runs a tool, streaming each output line (stdout and stderr merged) to `onLine`.
    /// Cancelling the calling task stops the process and throws `CancellationError`.
    @concurrent
    static func run(_ executable: URL,
                    arguments: [String],
                    environment: [String: String] = [:],
                    onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolPaths.searchPath
        env["PYTHONUNBUFFERED"] = "1"
        for (k, v) in environment { env[k] = v }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Output is taken as it arrives, so it's all there even if a helper holds the pipe open past the tool's end.
        let collected = LineCollector()
        let output = pipe.fileHandleForReading
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collected.finish().forEach(onLine)
            } else {
                collected.append(data).forEach(onLine)
            }
        }
        defer { output.readabilityHandler = nil }

        return try await withTaskCancellationHandler {
            // The handler is set before launch, so a tool that exits at once can't be missed.
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in c.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    c.resume(throwing: error)
                    return
                }
                // Cancelled in the moment before launch: the cancellation handler found nothing to stop.
                if Task.isCancelled { stop(process) }
            }
            await collected.waitUntilFinished(limit: outputDrainLimit)
            try Task.checkCancellation()
            let text = collected.text
            guard process.terminationStatus == 0 else {
                throw ProcessFailure(tool: executable.lastPathComponent, status: process.terminationStatus, output: text)
            }
            return text
        } onCancel: {
            stop(process)
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: terminationGrace)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Output cut into lines. Keeps the most recent lines, enough for any error message or JSON reply.
nonisolated final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = Data()
    private var finished = false

    /// Adds a chunk of output and returns the lines it completed.
    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        partial.append(data)
        var complete: [String] = []
        while let end = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = partial[partial.startIndex..<end]
            if !line.isEmpty { complete.append(String(decoding: line, as: UTF8.self)) }
            partial = Data(partial[partial.index(after: end)...])
        }
        keep(complete)
        return complete
    }

    /// The output has ended. Returns the last line if it had no line ending.
    func finish() -> [String] {
        lock.lock(); defer { lock.unlock() }
        finished = true
        guard !partial.isEmpty else { return [] }
        let last = [String(decoding: partial, as: UTF8.self)]
        partial = Data()
        keep(last)
        return last
    }

    private func keep(_ new: [String]) {
        lines += new
        if lines.count > 4000 { lines.removeFirst(lines.count - 3000) }
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        let tail = partial.isEmpty ? [] : [String(decoding: partial, as: UTF8.self)]
        return (lines + tail).joined(separator: "\n")
    }

    func waitUntilFinished(limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !isFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
