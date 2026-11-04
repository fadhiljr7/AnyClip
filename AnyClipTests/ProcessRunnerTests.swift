//
//  ProcessRunnerTests.swift
//  AnyClipTests
//
//  Running command-line tools: their results, failures and being stopped.
//

import Testing
import Foundation
@testable import AnyClip

/// Off the main actor, so the stopwatch in these tests measures the tool and not other tests holding the main thread.
nonisolated struct ProcessRunnerTests {
    private let shell = URL(filePath: "/bin/sh")

    @Test func returnsWhatTheToolPrinted() async throws {
        let output = try await ProcessRunner.run(shell, arguments: ["-c", "echo one; echo two >&2"])
        #expect(output.contains("one") && output.contains("two"))
    }

    @Test func aFailingToolReportsItsStatusAndOutput() async {
        await #expect {
            _ = try await ProcessRunner.run(shell, arguments: ["-c", "echo 'ERROR: broke'; exit 3"])
        } throws: { error in
            let failure = error as? ProcessFailure
            return failure?.status == 3 && failure?.output.contains("broke") == true
        }
    }

    @Test func aMissingToolThrowsInsteadOfHanging() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessRunner.run(URL(filePath: "/nonexistent/tool"), arguments: [])
        }
    }

    /// Tools that end immediately used to be able to resume the wait twice, which crashes the app.
    @Test func manyInstantToolsInARow() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = try await ProcessRunner.run(URL(filePath: "/usr/bin/true"), arguments: []) }
            }
            try await group.waitForAll()
        }
    }

    @Test func cancellingStopsTheTool() async {
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(shell, arguments: ["-c", "exec sleep 30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aToolThatIgnoresBeingAskedToStopIsKilled() async {
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(shell, arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"]) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// A helper the tool started can hold the output open after the tool has ended; that mustn't hold up the queue.
    @Test func aHelperLeftBehindDoesntHoldUpTheResult() async throws {
        let started = ContinuousClock.now
        let output = try await ProcessRunner.run(shell, arguments: ["-c", "sleep 20 & echo done"])
        #expect(output.contains("done"))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func linesArriveWhole() {
        let collector = LineCollector()
        #expect(collector.append(Data("one\ntw".utf8)) == ["one"])
        #expect(collector.append(Data("o\r\nthr".utf8)) == ["two"])
        #expect(collector.text == "one\ntwo\nthr")
        #expect(collector.finish() == ["thr"])
        #expect(collector.text == "one\ntwo\nthr")
    }

    @Test func aLastLineWithoutAnEndingIsKept() async throws {
        let output = try await ProcessRunner.run(shell, arguments: ["-c", "printf 'no newline'"])
        #expect(output == "no newline")
    }

    @Test func aHugeSingleLineArrivesIntact() async throws {
        // yt-dlp's video details are one very long line of JSON.
        let output = try await ProcessRunner.run(shell, arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'; echo"])
        #expect(output.count == 3_000_000)
    }
}
