//
//  AIProviders.swift
//  AnyClip
//
//  Optional cloud providers. Keys are the user's own and stay in the Keychain.
//

import Foundation
import Security

nonisolated enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case apple, gemini, groq, openai, openrouter, anthropic, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: String(localized: "Apple Intelligence")
        case .gemini: "Google Gemini"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .anthropic: "Anthropic Claude"
        case .custom: String(localized: "Custom Provider")
        }
    }

    var needsKey: Bool { self != .apple }

    var defaultModel: String {
        switch self {
        case .apple: ""
        case .gemini: "gemini-3-flash-preview"
        case .groq: "qwen/qwen3.8-27b"
        case .openai: "gpt-5-mini"
        case .openrouter: "openrouter/free"
        case .anthropic: "claude-haiku-5-5"
        case .custom: "deepseek-v4.1-flash"
        }
    }

    /// Fixed choices shown as a menu; nil means the model is typed freely.
    var modelOptions: [String]? {
        switch self {
        case .gemini: ["gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-3.8-flash", "gemini-4-argon"]
        case .groq: ["qwen/qwen3.8-27b", "openai/gpt-oss-120b"]
        case .custom: ["deepseek-v4.1-flash", "glm-5.3", "kimi-k3", "gpt-6-sol", "mimo-v2.6-pro"]
        default: nil
        }
    }

    var keyPage: URL? {
        switch self {
        case .apple, .custom: nil
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        }
    }

    var note: String {
        switch self {
        case .apple: String(localized: "Free and private. Runs on this Mac.")
        case .gemini: String(localized: "Free tier available. Handles very long videos in one pass.")
        case .groq: String(localized: "Free tier available. Very fast; long videos are split into parts.")
        case .openai, .anthropic: String(localized: "Paid API. Uses your own key.")
        case .openrouter: String(localized: "Offers free models. Uses your own key.")
        case .custom: String(localized: "Any OpenAI-compatible API, such as a gateway that serves many models. Uses your own base URL and key.")
        }
    }

    /// Rough transcript budget per request, in characters.
    var transcriptBudget: Int {
        switch self {
        case .apple: 7_000
        case .gemini: 400_000
        case .groq: 18_000
        case .openai, .anthropic: 250_000
        case .openrouter: 60_000
        case .custom: 100_000
        }
    }

    var endpoint: URL {
        switch self {
        case .apple: URL(string: "about:blank")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        case .groq: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        case .custom: AIProvider.chatEndpoint(base: AIProvider.customBaseURL) ?? URL(string: "about:blank")!
        }
    }

    static let customBaseURLKey = "aiBaseURL.custom"

    static var customBaseURL: String { UserDefaults.standard.string(forKey: customBaseURLKey) ?? "" }

    /// The chat completions address under an OpenAI-compatible base URL such as `https://host/v1`.
    /// A full `…/chat/completions` address is used as it is. Nil unless it is https, or plain http to a server on
    /// this Mac or its network: the API key and transcript must not cross the internet unencrypted.
    static func chatEndpoint(base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              scheme == "https" || (scheme == "http" && isLocal(host: host)) else { return nil }
        return text.hasSuffix("/chat/completions") ? url : url.appending(path: "chat/completions")
    }

    private static func isLocal(host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }

    /// Where the transcript goes: the host for a custom provider, otherwise the provider's name.
    var recipient: String {
        guard self == .custom, let host = AIProvider.chatEndpoint(base: AIProvider.customBaseURL)?.host() else { return displayName }
        return host
    }

    static var selected: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: AppSettings.Key.aiProvider) ?? "") ?? .apple
    }

    var model: String {
        let custom = (UserDefaults.standard.string(forKey: AppSettings.Key.aiModel(self)) ?? "").trimmingCharacters(in: .whitespaces)
        if let options = modelOptions { return options.contains(custom) ? custom : defaultModel }
        return custom.isEmpty ? defaultModel : custom
    }

    var apiKey: String? { Keychain.read(account: rawValue) }
}

nonisolated struct KeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
        return String(localized: "The key couldn’t be saved in your Keychain: \(reason)")
    }
}

nonisolated enum Keychain {
    private static let service = "com.mufiiin.AnyClip.ai"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Replaces the saved key in one step, so a failure leaves the old key in place. An empty value removes it.
    static func save(_ value: String, account: String) throws {
        guard !value.isEmpty else { return delete(account: account) }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account: account)
            attributes[kSecValueData as String] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

nonisolated struct CloudAIError: LocalizedError {
    var provider: AIProvider
    var status: Int
    var message: String

    var errorDescription: String? { CloudAI.describe(self) }

    /// The key works but this model isn't part of the free tier. Gemini reports it as a quota of 0.
    var notInFreeTier: Bool {
        let m = message.lowercased()
        return status == 429 && (m.contains("limit: 0") || (m.contains("free") && !m.contains("limit:")))
    }

    /// Too many requests in a short time, or the day's quota is used up.
    var isRateLimited: Bool { status == 429 && !notInFreeTier }
}

nonisolated enum CloudAI {
    @concurrent
    static func complete(provider: AIProvider, system: String, prompt: String, json: Bool = true,
                         maxTokens: Int = 4096, model: String? = nil, timeout: TimeInterval = 180) async throws -> String {
        let model = model ?? provider.model
        guard let key = provider.apiKey else {
            throw CloudAIError(provider: provider, status: 401, message: "No key")
        }
        if provider == .custom, AIProvider.chatEndpoint(base: AIProvider.customBaseURL) == nil {
            throw CloudAIError(provider: provider, status: 0, message: String(localized: "Enter the provider’s base URL in Settings › AI."))
        }
        var request = makeRequest(provider: provider, endpoint: provider.endpoint, key: key, system: system, prompt: prompt,
                                  json: json, maxTokens: maxTokens, model: model, timeout: timeout)

        // Busy (503) and internal (500) errors are usually momentary, so retry twice.
        var attempt = 0
        var data = Data(), status = 0
        while true {
            let (d, response) = try await URLSession.shared.data(for: request)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            attempt += 1
            // Newer OpenAI models behind a gateway may only take max_completion_tokens.
            if provider == .custom, status == 400, attempt == 1,
               (errorMessage(from: data) ?? "").contains("max_tokens"),
               let fixed = renamingTokenLimit(request) {
                request = fixed
                continue
            }
            guard [500, 502, 503].contains(status), attempt < 3 else { break }
            engineLog("\(provider.displayName) \(model): HTTP \(status), retrying")
            try await Task.sleep(for: .seconds(Double(attempt) * 3))
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw CloudAIError(provider: provider, status: status, message: errorMessage(from: data) ?? "HTTP \(status)")
        }
        if provider == .anthropic {
            let content = object?["content"] as? [[String: Any]] ?? []
            return content.compactMap { $0["text"] as? String }.joined()
        }
        let choices = object?["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        var content = (message?["content"] as? String) ?? ""
        if provider == .custom { content = withoutThinking(content) }
        if content.isEmpty {
            let reason = choices.first?["finish_reason"] as? String ?? "unknown"
            throw CloudAIError(provider: provider, status: 0,
                               message: String(localized: "It sent an empty answer (reason: \(reason)).") )
        }
        return content
    }

    static func makeRequest(provider: AIProvider, endpoint: URL, key: String, system: String, prompt: String,
                            json: Bool, maxTokens: Int, model: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if provider == .openrouter {
                request.setValue("AnyClip", forHTTPHeaderField: "X-Title")
            }
            var b: [String: Any] = ["model": model,
                                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
            // Gateways pass requests to many model families; not all of them accept response_format.
            if json, provider != .openrouter, provider != .custom { b["response_format"] = ["type": "json_object"] }
            if provider == .gemini {
                // Gemini 3 thinks before answering and that counts against the output budget.
                b["reasoning_effort"] = "low"
                b["max_tokens"] = max(maxTokens, 16_384)
            } else if provider == .openai {
                b["max_completion_tokens"] = maxTokens
            } else if provider == .groq || provider == .custom {
                // Both Groq models, and most models behind a gateway, think before answering,
                // and that counts against the output budget. Qwen on Groq also writes its thinking into the answer unless told to keep it out.
                if provider == .groq, model.hasPrefix("qwen/") { b["reasoning_format"] = "hidden" }
                b["max_tokens"] = max(maxTokens, 8_192)
            } else {
                b["max_tokens"] = maxTokens
            }
            body = b
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The same request with `max_tokens` sent as `max_completion_tokens`, or nil if it has no `max_tokens`.
    static func renamingTokenLimit(_ request: URLRequest) -> URLRequest? {
        guard let data = request.httpBody,
              var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limit = body.removeValue(forKey: "max_tokens") else { return nil }
        body["max_completion_tokens"] = limit
        var fixed = request
        fixed.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return fixed
    }

    /// Some open models served through gateways write their reasoning into the answer between think tags.
    static func withoutThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pulls the human message out of an error body; Google wraps it in an array.
    static func errorMessage(from data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let dict = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        if let error = dict?["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = dict?["message"] as? String { return message }
        return String(data: data, encoding: .utf8).map { String($0.prefix(300)) }
    }

    /// A tiny request used by the Settings “Test” button.
    @concurrent
    static func test(provider: AIProvider, model: String? = nil) async throws {
        _ = try await complete(provider: provider, system: "Reply with JSON.", prompt: "Return {\"ok\":true}", maxTokens: 64, model: model, timeout: 45)
    }

    /// Model IDs the key can see (Gemini only), or nil when the list can't be fetched.
    @concurrent
    static func availableGeminiModels() async -> Set<String>? {
        guard let key = AIProvider.gemini.apiKey,
              var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return nil }
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        return Set(models.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") })
    }

    nonisolated enum ModelCheck: Sendable, Equatable {
        case working(seconds: Double)
        case failed(String)
    }

    /// Tries each model with a tiny request and explains failures in plain words.
    @concurrent
    static func check(provider: AIProvider, models: [String]) async -> [String: ModelCheck] {
        let listed = provider == .gemini ? await availableGeminiModels() : nil
        var results: [String: ModelCheck] = [:]
        for model in models {
            if let listed, !listed.contains(model) {
                results[model] = .failed(String(localized: "Not offered to your API key (unknown or unreleased model ID)."))
                continue
            }
            let started = Date()
            do {
                try await test(provider: provider, model: model)
                results[model] = .working(seconds: Date().timeIntervalSince(started))
            } catch let error as CloudAIError {
                engineLog("model check \(model): HTTP \(error.status) \(error.message.prefix(400))")
                results[model] = .failed(describe(error))
            } catch let error as URLError where error.code == .timedOut {
                results[model] = .failed(String(localized: "No answer within 45 seconds — \(provider.displayName) is overloaded for this model right now. Try again later."))
            } catch {
                engineLog("model check \(model): \(error) after \(Date().timeIntervalSince(started)) s")
                results[model] = .failed(error.localizedDescription)
            }
        }
        return results
    }

    static func describe(_ error: CloudAIError) -> String {
        let m = error.message.lowercased()
        switch error.status {
        case 404: return String(localized: "Model not found. The ID may be wrong or not released yet.")
        case 429 where error.notInFreeTier:
            return String(localized: "Not included in the free tier. It needs a paid (billing-enabled) key.")
        case 429:
            return String(localized: "\(error.provider.displayName) has reached its usage limit — too many requests in a short time, or today’s quota is used up. Switch to another model or AI provider in Settings › AI, or wait a few minutes and try again.")
        case 500, 502, 503: return String(localized: "\(error.provider.displayName) is overloaded for this model right now. Try again in a few minutes.")
        case 401: return String(localized: "\(error.provider.displayName) rejected the API key. Check it in Settings › AI.")
        case 403: return String(localized: "The key isn’t allowed to use this model.")
        case 400 where m.contains("not supported") || m.contains("not found"):
            return String(localized: "Model not available for this API: \(error.message)")
        default: return error.status == 0 ? error.message : "HTTP \(error.status): \(error.message)"
        }
    }

    /// Why a cloud provider couldn't be used, for a project or teaser that stops there.
    static func failureMessage(_ error: Error, provider: AIProvider) -> String {
        // The limit message already names the provider and says what to do; the model ID adds nothing.
        if let cloud = error as? CloudAIError, cloud.isRateLimited { return describe(cloud) }
        return String(localized: "\(provider.displayName) (\(provider.model)) failed: \(error.localizedDescription)")
    }

    /// The notice shown when Apple Intelligence stepped in for a cloud provider.
    static func fallbackNotice(_ error: Error, provider: AIProvider) -> String {
        if let cloud = error as? CloudAIError, cloud.isRateLimited {
            return String(localized: "\(provider.displayName) has reached its usage limit, so Apple Intelligence was used instead. To keep using \(provider.displayName), switch to another model in Settings › AI or wait a few minutes.")
        }
        return String(localized: "\(provider.displayName) didn’t respond: \(error.localizedDescription) Apple Intelligence was used instead.")
    }
}

nonisolated enum LooseJSON {
    /// A whole number however the model wrote it: 12, 12.0, "12" or, with the prefix, "L12".
    static func int(_ value: Any?, prefix: String = "") -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double, v.isFinite, abs(v) < 1e15 { return Int(v) }
        if let v = value as? String { return Int(v.trimmingCharacters(in: CharacterSet(charactersIn: prefix + " "))) }
        return nil
    }

    /// Pulls the first JSON object or array out of a model reply (handles ``` fences and chatter).
    static func object(from text: String) -> Any? {
        var s = text
        if let fence = s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if s.hasPrefix("json") { s = String(s.dropFirst(4)) }
            if let close = s.range(of: "```") { s = String(s[..<close.lowerBound]) }
        }
        guard let startIdx = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = s[startIdx], close: Character = open == "{" ? "}" : "]"
        guard let endIdx = s.lastIndex(of: close), endIdx > startIdx else { return nil }
        let slice = String(s[startIdx...endIdx])
        return try? JSONSerialization.jsonObject(with: Data(slice.utf8))
    }
}
