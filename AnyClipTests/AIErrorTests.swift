//
//  AIErrorTests.swift
//  AnyClipTests
//
//  What people are told when a cloud AI provider can't be used.
//

import Testing
import Foundation
@testable import AnyClip

struct AIErrorTests {
    let groqLimit = CloudAIError(provider: .groq, status: 429, message: "Rate limit reached for model `qwen/qwen3.8-27b` in organization `org_x` service tier `on_demand` on input tokens per minute (ITPM): Limit 7000, Used 5135, Requested 2150. Please try again in 2.442857142s. Need more tokens? Upgrade to Dev Tier today at https://console.groq.com/settings/billing")
    /// Gemini names its free-tier quotas "…free_tier…", so "free" alone doesn't mean the model is paid-only.
    let geminiDailyQuota = CloudAIError(provider: .gemini, status: 429, message: "You exceeded your current quota. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: gemini-3-flash")
    let geminiPaidOnly = CloudAIError(provider: .gemini, status: 429, message: "Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 0, model: gemini-3.1-pro")

    @Test func rateLimitsAreRecognised() {
        #expect(groqLimit.isRateLimited)
        #expect(geminiDailyQuota.isRateLimited)
        #expect(!geminiPaidOnly.isRateLimited)
        #expect(geminiPaidOnly.notInFreeTier)
        #expect(!CloudAIError(provider: .groq, status: 503, message: "busy").isRateLimited)
    }

    @Test func aRateLimitSaysWhatToDoInsteadOfShowingTheRawError() {
        let text = CloudAI.failureMessage(groqLimit, provider: .groq)
        #expect(text == CloudAI.describe(groqLimit))
        #expect(text.contains(AIProvider.groq.displayName))
        // Nothing from the raw reply leaks into it.
        #expect(!text.contains("ITPM") && !text.contains("org_x") && !text.contains("429"))
        #expect(CloudAI.fallbackNotice(groqLimit, provider: .groq).contains(AIProvider.groq.displayName))
    }

    @Test func otherFailuresStillNameTheModel() {
        let busy = CloudAIError(provider: .groq, status: 503, message: "busy")
        #expect(CloudAI.failureMessage(busy, provider: .groq).contains(AIProvider.groq.model))
    }
}
