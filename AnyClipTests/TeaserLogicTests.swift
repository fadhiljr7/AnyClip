//
//  TeaserLogicTests.swift
//  AnyClipTests
//
//  Regression tests for the teaser's pure logic: telling repeated lines apart,
//  phrase and cut-point handling, the output timeline and composition ticks.
//

import Testing
import CoreMedia
@testable import AnyClip

/// Words spaced evenly, `step` seconds each, back to back like YouTube timings.
func words(_ text: String, from start: Double = 0, step: Double = 0.4) -> [Word] {
    text.split(separator: " ").enumerated().map { i, w in
        Word(text: String(w), start: start + Double(i) * step, end: start + Double(i + 1) * step)
    }
}

struct RepeatTests {
    @Test func hookThatRewordsTheTeaserIsARepeat() {
        // The case from testing: the hook and the teaser both say "you'll stay poor for life".
        #expect(TeaserText.repeats("Kalau lu cuman kerja keras, lu bakal tetap miskin seumur hidup.",
                                   "Lu akan terus ya jadi orang miskin seumur hidup."))
        #expect(TeaserText.repeats("Why You'll Stay Poor for the Rest of Your Life",
                                   "You'll stay poor for the rest of your life."))
    }

    @Test func hookThatAddsContextIsNotARepeat() {
        #expect(!TeaserText.repeats("The Business Mistake That Nearly Ruined Everything", "I lost Rp5 billion in a single night!"))
        #expect(!TeaserText.repeats("Allison left me this Post-it note a decade ago.", "From the inside, it's sacred."))
        #expect(!TeaserText.repeats("Kenapa kerja keras saja nggak cukup?", "Lu akan terus ya jadi orang miskin seumur hidup."))
    }

    @Test func indonesianSuffixesAndStopwordsDontCount() {
        #expect(TeaserText.contentWords("hidupnya lu itu yang") == ["hidup"])
        #expect(TeaserText.contentWords("You'd be wrong.") == ["wrong"])
    }

    @Test func emptyLinesNeverRepeat() {
        #expect(!TeaserText.repeats("", "anything at all"))
        #expect(!TeaserText.repeats("yang dan itu", "yang dan itu"))
    }
}

struct PhraseAndCutTests {
    @Test func phrasesBreakAtSentenceEndsAndPauses() {
        var ws = words("Saya kaget banget. Ternyata semua uangnya hilang")
        for i in 5...6 { ws[i].start += 1; ws[i].end += 1 }   // a pause before "uangnya"
        let phrases = TeaserText.phrases(ws)
        #expect(phrases.map(\.text) == ["Saya kaget banget.", "Ternyata semua", "uangnya hilang"])
        #expect(phrases.map(\.number) == [1, 2, 3])
    }

    @Test func quoteAlignsToTheMatchingWords() {
        let ws = words("and now what we think is simplifying our lives is actually complicating our future?")
        let range = TeaserText.align(quote: "actually complicating our future?", in: ws, range: 0...(ws.count - 1))
        #expect(range == 10...13)
        #expect(TeaserText.align(quote: "something the speaker never said", in: ws, range: 0...(ws.count - 1)) == nil)
    }

    @Test func cutPointsNeverReachIntoNeighbouringWords() {
        let ws = words("mahal. Lu akan terus miskin")
        let cut = TeaserText.cutPoints(words: ws, range: 1...4)
        #expect(cut.start >= ws[0].end)
        #expect(cut.end >= ws[4].end)
    }

    @Test func aWordBelongsToTheCutOnlyWhenItsMiddleIsInside() {
        // Regression: a cut a few milliseconds before "Lu" showed "mahal. Lu akan…" as the teaser text.
        let ws = words("mahal. Lu akan terus miskin")
        #expect(TeaserText.wordRange(start: ws[1].start - 0.03, end: ws[4].end + 0.05, in: ws) == 1...4)
    }

    @Test func aLastWordStretchedOverAPauseStillBelongsToTheCut() {
        // Regression: YouTube timed "sacred." as 655.88–658.19 (it absorbs the pause after it). The cut ends where the
        // voice stops, at 656.42, and the teaser text came out as "From the inside, it's".
        let ws = [Word(text: "From", start: 654.12, end: 654.40), Word(text: "the", start: 654.40, end: 654.52),
                  Word(text: "inside,", start: 654.52, end: 655.64), Word(text: "it's", start: 655.64, end: 655.88),
                  Word(text: "sacred.", start: 655.88, end: 658.19), Word(text: "We're", start: 658.20, end: 658.32)]
        #expect(TeaserText.wordRange(start: 654.105, end: 656.415, in: ws) == 0...4)
    }
}

struct TeaserFinderRuleTests {
    @Test func sameMessageTwiceKeepsTheStrongerOne() {
        let a = TeaserCandidate(angle: .statement, start: 10, end: 12, text: "Lu bakal miskin seumur hidup", reason: "", score: 9)
        let b = TeaserCandidate(angle: .emotion, start: 30, end: 32, text: "miskin seumur hidup, percuma", reason: "", score: 7)
        let c = TeaserCandidate(angle: .curiosity, start: 50, end: 52, text: "Siapa yang dimenangkan inflasi?", reason: "", score: 8)
        let kept = TeaserFinder.distinct([b, a, c])
        #expect(kept.map(\.score) == [9, 8])
    }

    @Test func overlongPickKeepsItsClosingSentences() {
        let ws = words("That's the thing about a love note.", step: 0.3)
            + words("To the outside world, it looks trivial.", from: 2.1, step: 0.45)
            + words("From the inside, it's sacred.", from: 5.3, step: 0.5)
        let phrases = TeaserText.phrases(ws)
        let ending = TeaserFinder.ending(of: 0...(ws.count - 1), words: ws, phrases: phrases)
        #expect(ending.map { ws[$0.lowerBound].text } == "To")
    }

    @Test func setupForAShortReplyMustBeAWholeSentence() {
        let ws = words("Most people say couples should share hobbies. Similar couples should last longer. You'd be wrong.", step: 0.3)
        let phrases = TeaserText.phrases(ws)
        let reply = (ws.count - 3)...(ws.count - 1)
        let longer = TeaserFinder.withSetup(reply, words: ws, phrases: phrases, firstUsable: 1, limit: 4.5)
        #expect(longer.map { ws[$0.lowerBound].text } == "Similar")
        // When the sentence before doesn't fit, the reply is left as it is.
        #expect(TeaserFinder.withSetup(reply, words: ws, phrases: phrases, firstUsable: 1, limit: 1.5) == nil)
    }
}

struct TimelineTests {
    let timeline = OutputTimeline(teaser: ClipSegment(start: 40, end: 42.5), main: ClipSegment(start: 30, end: 60))

    @Test func teaserComesFirstThenTheClip() {
        #expect(timeline.duration == 32.5)
        #expect(timeline.pieces.map { $0.offset } == [0, 2.5])
        #expect(timeline.isTeaser(output: 1))
        #expect(!timeline.isTeaser(output: 3))
    }

    @Test func outputAndSourceTimesMapBothWays() {
        #expect(timeline.source(forOutput: 1) == 41)
        #expect(timeline.source(forOutput: 2.5) == 30)
        #expect(timeline.output(forSource: 30) == 2.5)
        #expect(timeline.output(forSource: 40) == 12.5)
    }

    @Test func withoutTeaserNothingMoves() {
        let plain = OutputTimeline(main: ClipSegment(start: 30, end: 60))
        #expect(plain.duration == 30)
        #expect(plain.output(forSource: 45) == 15)
        #expect(plain.source(forOutput: 15) == 45)
    }

    @Test func compositionTicksRoundInsteadOfTruncating() {
        // Regression: CMTime(seconds:) truncated 2.3083… s to tick 1384, inside the teaser's last camera ramp,
        // and AVFoundation threw. Ticks must round to 1385.
        #expect(CompositionBuilder.ticks(1385.0 / 600.0).value == 1385)
        #expect(CompositionBuilder.ticks(2.3083333333333).value == 1385)
        #expect(CompositionBuilder.ticks(0.0009).value == 1)
    }
}

struct TeaserPlanTests {
    @Test func suggestionsGoStaleWhenTheClipIsTrimmed() {
        var plan = TeaserPlan()
        plan.candidates = [TeaserCandidate(angle: .statement, start: 40, end: 42, text: "x", reason: "")]
        plan.analyzed = ClipSegment(start: 30, end: 60)
        #expect(!plan.isStale(start: 30.4, end: 60))
        #expect(plan.isStale(start: 35, end: 60))
        #expect(!TeaserPlan().isStale(start: 0, end: 10))
    }

    @Test func plansSavedBeforeTheAnalyzedRangeStillLoad() throws {
        let old = #"{"candidates":[],"start":0,"end":0,"source":"Groq"}"#
        let plan = try JSONDecoder().decode(TeaserPlan.self, from: Data(old.utf8))
        #expect(plan.analyzed == nil)
        #expect(plan.source == "Groq")
    }
}
