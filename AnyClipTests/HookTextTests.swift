//
//  HookTextTests.swift
//  AnyClipTests
//
//  Regression tests for the checks every AI-written hook passes before it's offered.
//

import Testing
@testable import AnyClip

struct HookTextTests {
    let transcript = """
    Allison left me this Post-it note a decade ago. To the outside world, it looks trivial. \
    From the inside, it's sacred. It has survived ten moves.
    """

    func request(teaser: String?) -> HookRequest {
        HookRequest(transcript: transcript, title: "This sticky note survived 10 moves",
                    currentHook: "Allison left me this Post-it note a decade ago.", teaser: teaser, language: "en")
    }

    @Test func withTeaserRewordingsOfItAreDropped() {
        let hooks = HookText.usable([
            "From the inside, this note is sacred",
            "Why would anyone keep a Post-it for ten years?",
        ], request: request(teaser: "From the inside, it's sacred."))
        #expect(hooks == ["Why would anyone keep a Post-it for ten years?"])
    }

    @Test func suggestionsMayNotReuseHalfTheTeasersKeyWords() {
        // Seen with Groq: adds a contrast, but still leans on the teaser's key word.
        let hooks = HookText.usable(["The outside calls it trivial, I call it sacred.", "Nothing to them, but it means everything to us."],
                                    request: request(teaser: "From the inside, it's sacred."))
        #expect(hooks == ["Nothing to them, but it means everything to us."])
    }

    @Test func withoutTeaserTheSameLineIsFine() {
        let hooks = HookText.usable(["From the inside, this note is sacred"], request: request(teaser: nil))
        #expect(hooks == ["From the inside, this note is sacred"])
    }

    @Test func numbersTheSpeakerNeverSaidAreDropped() {
        // The speaker says "ten", so a hook claiming "10 moves" isn't backed by the words on screen.
        let hooks = HookText.usable(["This note survived 10 moves", "A note that outlasted every move"], request: request(teaser: nil))
        #expect(hooks == ["A note that outlasted every move"])
    }

    @Test func currentHookDuplicatesAndLongLinesAreDropped() {
        let hooks = HookText.usable([
            "Allison left me this Post-it note a decade ago.",
            "Why one small note still matters after all these years",
            "Why one small note still matters after all this time",
            "This is a very long hook that keeps going and going well past the sixteen word limit for the screen",
        ], request: request(teaser: nil))
        #expect(hooks == ["Why one small note still matters after all these years"])
    }

    @Test func decorationIsCleanedOff() {
        #expect(HookText.clean("1. \u{201C}Why keep a Post-it?\u{201D} ") == "Why keep a Post-it?")
        #expect(HookText.clean("- The note he never threw away") == "The note he never threw away")
    }

    @Test func numbersWrittenAsWordsAreCheckedToo() {
        // Seen with Groq: "Moved my office ten times" — the speaker only says "I've moved offices since then".
        let r = HookRequest(transcript: "I've moved offices since then. This Post-it note moved with me.", title: "",
                            currentHook: "", teaser: nil, language: "en")
        #expect(HookText.usable(["Moved my office ten times, it never left.", "It moved with me through every office"], request: r)
                == ["It moved with me through every office"])
    }

    @Test func numberParsingIgnoresThousandsSeparators() {
        #expect(HookText.numbers("Rp5.000 dan 10 juta") == ["5000", "10", "juta"])
        #expect(HookText.numbers("no numbers here").isEmpty)
    }

    @Test func hooksInTheWrongLanguageAreDropped() {
        let hooks = HookText.usable(["Kenapa catatan kecil ini lebih berarti daripada cincin berlian"], request: request(teaser: nil))
        #expect(hooks.isEmpty)
    }
}
