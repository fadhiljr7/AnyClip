//
//  PreviewRegressionTests.swift
//  AnyClipTests
//
//  Reading a transcript while drawing must not make the view draw again. It once
//  did, which froze the app the moment a teaser was chosen.
//

import Testing
import Foundation
import Observation
@testable import AnyClip

@MainActor
struct PreviewRegressionTests {
    @Test func readingATranscriptDoesntInvalidateTheReader() throws {
        let project = Project(title: "t", sourceURL: nil, options: ProjectOptions())
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let transcript = Transcript(language: "en", words: [Word(text: "hello", start: 0, end: 1)])
        try JSONEncoder().encode(transcript).write(to: project.transcriptURL)

        let invalidated = Invalidated()
        for _ in 0..<3 {
            withObservationTracking {
                #expect(Studio.shared.transcript(for: project)?.words.count == 1)
            } onChange: {
                invalidated.mark()
            }
        }
        #expect(!invalidated.happened)
    }
}

private final class Invalidated: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var happened: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func mark() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
