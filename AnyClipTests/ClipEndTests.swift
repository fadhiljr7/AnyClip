//
//  ClipEndTests.swift
//  AnyClip
//
//  Clips end on a finished sentence and never run into the next one.
//

import Testing
import Foundation
@testable import AnyClip

struct ClipEndTests {
    /// YouTube stretches each word's end to the next word's start, so line ends touch the next line.
    let lines = [
        TranscriptLine(index: 0, start: 0, end: 8, text: "Rules are what make a game fun,"),
        TranscriptLine(index: 1, start: 8, end: 16, text: "and that is why we play them."),
        TranscriptLine(index: 2, start: 16, end: 33, text: "Kids skip and hop and wander around the playground"),
        TranscriptLine(index: 3, start: 33, end: 40, text: "because they want to.”"),
        TranscriptLine(index: 4, start: 40, end: 48, text: "Amazing. I love that."),
    ]

    @Test func sentenceEndsAreRecognised() {
        #expect(MomentFinder.endsSentence(lines[1]))
        #expect(MomentFinder.endsSentence(lines[3]))   // closing quote after the period
        #expect(!MomentFinder.endsSentence(lines[0]))
        #expect(!MomentFinder.endsSentence(lines[2]))
    }

    @Test func aClipFinishesTheSentenceItStopsIn() {
        // Stopping after line 2 would cut "…around the playground" off mid-sentence.
        #expect(MomentFinder.sentenceEnd(near: 2, from: 0, lines: lines, range: 15...45) == 3)
        // Too long to finish it: stop after the previous sentence instead.
        #expect(MomentFinder.sentenceEnd(near: 2, from: 0, lines: lines, range: 15...35) == 1)
        #expect(MomentFinder.sentenceEnd(near: 1, from: 0, lines: lines, range: 10...45) == 1)
    }

    @Test func theEndIsNotPaddedIntoTheNextLine() {
        // Auto length allows these 40 seconds.
        let request = MomentRequest(lines: lines, count: 1, length: .auto, language: "en", videoTitle: "", channel: "", topic: "")
        let moment = MomentCandidate(start: 0, end: 39, title: "t", hook: "h", summary: "", category: .story, score: 9)
        let end = MomentFinder.finalize([moment], request: request).first?.end ?? 99
        // Line 3 ends exactly where "Amazing." starts; the cut must stay before it.
        #expect(end <= 40)
    }
}
