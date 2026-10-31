//
//  CustomProviderTests.swift
//  AnyClipTests
//
//  An OpenAI-compatible gateway the user points AnyClip at with a base URL.
//

import Testing
import Foundation
@testable import AnyClip

struct CustomProviderTests {
    @Test func theBaseURLLeadsToChatCompletions() {
        let expected = "https://api.example.com/v1/chat/completions"
        #expect(AIProvider.chatEndpoint(base: "https://api.example.com/v1")?.absoluteString == expected)
        #expect(AIProvider.chatEndpoint(base: " https://api.example.com/v1/ \n")?.absoluteString == expected)
        // A full address pasted from the provider's docs is used as it is.
        #expect(AIProvider.chatEndpoint(base: expected)?.absoluteString == expected)
        #expect(AIProvider.chatEndpoint(base: "") == nil)
        #expect(AIProvider.chatEndpoint(base: "api.example.com/v1") == nil)
        #expect(AIProvider.chatEndpoint(base: "ftp://api.example.com/v1") == nil)
    }

    @Test func theModelMenuListsTheGatewayModels() {
        #expect(AIProvider.custom.modelOptions == ["deepseek-v4.1-flash", "glm-5.3", "kimi-k3", "gpt-6-sol", "mimo-v2.6-pro"])
        #expect(AIProvider.custom.modelOptions?.contains(AIProvider.custom.defaultModel) == true)
        #expect(AIProvider.custom.needsKey)
    }

    @Test func requestsAreOpenAIStyleWithTheChosenModel() throws {
        let endpoint = try #require(AIProvider.chatEndpoint(base: "https://api.example.com/v1"))
        let request = CloudAI.makeRequest(provider: .custom, endpoint: endpoint, key: "test-key", system: "sys", prompt: "hi",
                                          json: true, maxTokens: 4096, model: "kimi-k3", timeout: 30)
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "kimi-k3")
        #expect((body["messages"] as? [[String: String]])?.map { $0["role"] } == ["system", "user"])
        // Not every model behind a gateway accepts response_format; replies are parsed loosely instead.
        #expect(body["response_format"] == nil)
        #expect(body["max_tokens"] as? Int == 8192)
    }

    @Test func aModelThatRejectsMaxTokensGetsMaxCompletionTokens() throws {
        let endpoint = try #require(AIProvider.chatEndpoint(base: "https://api.example.com/v1"))
        let request = CloudAI.makeRequest(provider: .custom, endpoint: endpoint, key: "k", system: "s", prompt: "p",
                                          json: true, maxTokens: 64, model: "gpt-6-sol", timeout: 30)
        let fixed = try #require(CloudAI.renamingTokenLimit(request))
        let body = try #require(JSONSerialization.jsonObject(with: fixed.httpBody ?? Data()) as? [String: Any])
        #expect(body["max_tokens"] == nil)
        #expect(body["max_completion_tokens"] as? Int == 8192)
        #expect(body["model"] as? String == "gpt-6-sol")
    }

    @Test func thinkingWrittenIntoTheAnswerIsDropped() {
        #expect(CloudAI.withoutThinking("<think>maybe {x}</think>\n{\"ok\":true}") == "{\"ok\":true}")
        #expect(CloudAI.withoutThinking("{\"ok\":true}") == "{\"ok\":true}")
    }
}
