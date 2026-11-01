//
//  YouTubeAuth.swift
//  AnyClip
//
//  Connects a YouTube account with Google's OAuth flow for desktop apps: the
//  browser signs in and redirects to a one-time listener on this Mac. The
//  person's own Google client and the refresh token stay in the Keychain.
//

import CryptoKit
import Foundation
import Network
import Observation
import Security
import AppKit

nonisolated enum YouTubeCredentials {
    private static let clientIDAccount = "youtube.clientID"
    private static let clientSecretAccount = "youtube.clientSecret"
    private static let refreshTokenAccount = "youtube.refreshToken"

    static var clientID: String? { Keychain.read(account: clientIDAccount) }
    static var clientSecret: String? { Keychain.read(account: clientSecretAccount) }
    static var refreshToken: String? { Keychain.read(account: refreshTokenAccount) }

    static func saveClient(id: String, secret: String) throws {
        try Keychain.save(id.trimmingCharacters(in: .whitespacesAndNewlines), account: clientIDAccount)
        try Keychain.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), account: clientSecretAccount)
    }

    static func saveRefreshToken(_ token: String) throws { try Keychain.save(token, account: refreshTokenAccount) }
    static func removeRefreshToken() { Keychain.delete(account: refreshTokenAccount) }

    /// Reads the client file Google Cloud offers for download.
    static func parseClientFile(_ data: Data) -> (id: String, secret: String)? {
        struct File: Decodable {
            struct Client: Decodable {
                let client_id: String
                let client_secret: String?
            }
            let installed: Client?
            let web: Client?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), let client = file.installed ?? file.web else { return nil }
        return (client.client_id, client.client_secret ?? "")
    }
}

nonisolated enum OAuthPKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What the browser's redirect to this Mac said.
nonisolated enum OAuthRedirect: Equatable {
    case code(String)
    case denied(String)
    /// Something else, such as a favicon request or a stale page: keep waiting.
    case ignored

    /// `requestLine` is the first line of the HTTP request, e.g. `GET /?state=x&code=y HTTP/1.1`.
    static func parse(requestLine: String, expectedState: String) -> OAuthRedirect {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let items = URLComponents(string: String(parts[1]))?.queryItems else { return .ignored }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return .ignored }
        if let code = value("code") { return .code(code) }
        if let error = value("error") { return .denied(error) }
        return .ignored
    }
}

/// Listens once on 127.0.0.1 for the browser's redirect.
nonisolated final class OAuthLoopback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AnyClip.OAuthLoopback")
    private var pending: CheckedContinuation<OAuthRedirect, Error>?
    private var result: Result<OAuthRedirect, Error>?
    private let expectedState: String

    init(expectedState: String) throws {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port it got.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // Each state resumes at most once: the handler is removed first, and runs one at a time on the queue.
            let listener = self.listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func redirect() async throws -> OAuthRedirect {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.pending = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ outcome: Result<OAuthRedirect, Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = outcome
            self.pending?.resume(with: outcome)
            self.pending = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let redirect = OAuthRedirect.parse(requestLine: line, expectedState: self.expectedState)
            let page = redirect == .ignored ? "" : Self.page(for: redirect)
            let status = redirect == .ignored ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if redirect != .ignored { self.finish(.success(redirect)) }
        }
    }

    private static func page(for redirect: OAuthRedirect) -> String {
        let message: String
        if case .denied = redirect {
            message = "AnyClip wasn’t connected. You can close this tab."
        } else {
            message = "AnyClip is connected to YouTube. You can close this tab."
        }
        return "<!doctype html><meta charset=utf-8><title>AnyClip</title><body style=\"font:17px -apple-system;text-align:center;padding:64px\">\(message)</body>"
    }
}

/// Exchanges and refreshes tokens. Access tokens live only in memory.
actor YouTubeTokens {
    static let shared = YouTubeTokens()

    private var access: (token: String, expires: Date)?
    private static let endpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private struct Reply: Decodable {
        let access_token: String?
        let expires_in: Double?
        let refresh_token: String?
        let error: String?
    }

    func accessToken() async throws -> String {
        if let access, access.expires > Date().addingTimeInterval(60) { return access.token }
        guard let refresh = YouTubeCredentials.refreshToken else { throw YouTubeError.notConnected }
        guard let clientID = YouTubeCredentials.clientID else { throw YouTubeError.notConfigured }
        let reply = try await post(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        guard let token = reply.access_token else {
            if reply.error == "invalid_grant" {
                YouTubeCredentials.removeRefreshToken()
                throw YouTubeError.signInExpired
            }
            throw YouTubeError.signInDenied(reply.error ?? "unknown")
        }
        access = (token, Date().addingTimeInterval(reply.expires_in ?? 3000))
        return token
    }

    /// Turns the one-time code from the browser into a saved refresh token.
    func redeem(code: String, verifier: String, redirectURI: String) async throws {
        guard let clientID = YouTubeCredentials.clientID else { throw YouTubeError.notConfigured }
        let reply = try await post(["client_id": clientID, "code": code, "code_verifier": verifier,
                                    "grant_type": "authorization_code", "redirect_uri": redirectURI])
        guard let refresh = reply.refresh_token, let token = reply.access_token else {
            throw YouTubeError.signInDenied(reply.error ?? "no refresh token")
        }
        try YouTubeCredentials.saveRefreshToken(refresh)
        access = (token, Date().addingTimeInterval(reply.expires_in ?? 3000))
    }

    func forget() { access = nil }

    private func post(_ fields: [String: String]) async throws -> Reply {
        var fields = fields
        if let secret = YouTubeCredentials.clientSecret { fields["client_secret"] = secret }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/:")
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}

/// The connected account, as the interface sees it.
@MainActor
@Observable
final class YouTubeAccount {
    static let shared = YouTubeAccount()
    private static let channelKey = "youtubeChannelName"
    nonisolated private static let scopes = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly"

    private(set) var isConnected = YouTubeCredentials.refreshToken != nil
    private(set) var channelName = UserDefaults.standard.string(forKey: channelKey) ?? ""
    private(set) var isConnecting = false
    private(set) var lastError: String?
    private var connecting: Task<Void, Never>?

    /// The address the browser opens, with everything Google needs.
    nonisolated static func authorizationURL(clientID: String, redirectURI: String, state: String, challenge: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    func connect() {
        guard !isConnecting else { return }
        guard let clientID = YouTubeCredentials.clientID else {
            lastError = YouTubeError.notConfigured.errorDescription
            return
        }
        isConnecting = true
        lastError = nil
        connecting = Task {
            defer {
                isConnecting = false
                connecting = nil
            }
            do {
                try await signIn(clientID: clientID)
                isConnected = true
                await refreshChannelName()
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func cancelConnecting() { connecting?.cancel() }

    private func signIn(clientID: String) async throws {
        let state = UUID().uuidString
        let verifier = OAuthPKCE.verifier()
        let loopback = try OAuthLoopback(expectedState: state)
        defer { loopback.stop() }
        let port = try await loopback.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        guard let url = Self.authorizationURL(clientID: clientID, redirectURI: redirectURI, state: state,
                                              challenge: OAuthPKCE.challenge(for: verifier)) else { throw YouTubeError.notConfigured }
        NSWorkspace.shared.open(url)
        switch try await loopback.redirect() {
        case .code(let code):
            try await YouTubeTokens.shared.redeem(code: code, verifier: verifier, redirectURI: redirectURI)
        case .denied(let reason):
            throw reason == "access_denied" ? YouTubeError.signInCancelled : YouTubeError.signInDenied(reason)
        case .ignored:
            throw YouTubeError.signInCancelled
        }
    }

    func refreshChannelName() async {
        do {
            let token = try await YouTubeTokens.shared.accessToken()
            let name = try await YouTubeClient.channelName(token: token)
            channelName = name
            UserDefaults.standard.set(name, forKey: Self.channelKey)
        } catch {
            engineLog("couldn't read the YouTube channel: \(error.localizedDescription)")
            if case YouTubeError.signInExpired = error { markDisconnected() }
        }
    }

    func disconnect() {
        let token = YouTubeCredentials.refreshToken
        YouTubeCredentials.removeRefreshToken()
        markDisconnected()
        Task {
            await YouTubeTokens.shared.forget()
            // Best effort: the grant also goes away from Google's side.
            guard let token, var components = URLComponents(string: "https://oauth2.googleapis.com/revoke") else { return }
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func markDisconnected() {
        isConnected = false
        channelName = ""
        UserDefaults.standard.removeObject(forKey: Self.channelKey)
    }
}
