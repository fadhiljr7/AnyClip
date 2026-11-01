//
//  YouTubeTests.swift
//  AnyClipTests
//
//  Auto Schedule times, what YouTube is told, signing in and the resumable upload.
//

import Testing
import Foundation
@testable import AnyClip

struct YouTubeScheduleTests {
    private let jakarta = TimeZone(identifier: "Asia/Jakarta")!

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test func theExampleInTheRequest() throws {
        let first = try date("2026-11-02T01:00:00+07:00")
        let times = AutoSchedule(first: first, every: 1, unit: .hours).times(count: 3)
        #expect(times.map { YouTubeTime.publishAt($0, timeZone: jakarta) } ==
                ["2026-11-02T01:00:00+07:00", "2026-11-02T02:00:00+07:00", "2026-11-02T03:00:00+07:00"])
    }

    @Test func intervalsCanBeMinutesHoursOrDays() throws {
        let first = try date("2026-11-02T23:30:00+07:00")
        let f = { (t: [Date]) in t.map { YouTubeTime.publishAt($0, timeZone: self.jakarta) } }
        #expect(f(AutoSchedule(first: first, every: 45, unit: .minutes).times(count: 2))[1] == "2026-11-03T00:15:00+07:00")
        #expect(f(AutoSchedule(first: first, every: 3, unit: .days).times(count: 2))[1] == "2026-11-05T23:30:00+07:00")
        #expect(AutoSchedule(first: first, every: 1, unit: .hours).times(count: 0).isEmpty)
    }

    @Test func timesShowIn24HourLocalTime() throws {
        let en = Locale(identifier: "en_US")
        #expect(YouTubeTime.display(try date("2026-11-02T18:05:00+07:00"), timeZone: jakarta, locale: en) == "2 Nov 2026, 18:05")
        #expect(YouTubeTime.display(try date("2026-11-02T06:00:00+07:00"), timeZone: jakarta, locale: en) == "2 Nov 2026, 06:00")
    }

    @Test func theFirstSlotMustLeaveTimeToUpload() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AutoSchedule(first: now.addingTimeInterval(60), every: 1, unit: .hours).isInTime(now: now))
        #expect(AutoSchedule(first: now.addingTimeInterval(16 * 60), every: 1, unit: .hours).isInTime(now: now))
    }

    @Test func theSuggestedFirstSlotIsAWholeHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jakarta
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let suggested = AutoSchedule.suggestedFirst(now: now, calendar: calendar)
        #expect(calendar.component(.minute, from: suggested) == 0)
        #expect(suggested >= now.addingTimeInterval(3600))
    }

    @Test func quotaResetsAtMidnightPacific() throws {
        let reset = YouTubeTime.nextQuotaReset(after: try date("2026-11-02T06:00:00+07:00"))
        // Still 1 November in California, where the next midnight falls after clocks went back.
        #expect(YouTubeTime.publishAt(reset, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-11-02T00:00:00-08:00")
    }
}

struct YouTubeDraftTests {
    @Test func titleAndCaptionPassThrough() {
        let draft = YouTubeDraft(title: "Rugi 50 Persen", caption: "Matematika kehancuran.\n\nBaris kedua.")
        #expect(draft.title == "Rugi 50 Persen")
        #expect(draft.description == "Matematika kehancuran.\n\nBaris kedua.")
    }

    @Test func whatYouTubeRefusesIsCleaned() {
        let draft = YouTubeDraft(title: "  a <b>  c\nd ", caption: "x <y> z")
        #expect(draft.title == "a b c d")
        #expect(draft.description == "x y z")
        #expect(YouTubeDraft(title: String(repeating: "é", count: 150), caption: "").title.count == 100)
        #expect(YouTubeDraft(title: "<>", caption: "").title == String(localized: "Untitled clip"))
    }

    @Test func descriptionsFitInBytesNotCharacters() {
        let draft = YouTubeDraft(title: "t", caption: String(repeating: "🎬", count: 2000))
        #expect(draft.description.utf8.count <= 5000)
        #expect(draft.description.hasSuffix("🎬"))
    }

    @Test func aScheduledVideoStaysPrivateUntilItsTime() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Jakarta"))
        let at = try #require(ISO8601DateFormatter().date(from: "2026-11-02T06:00:00+07:00"))
        let data = try YouTubeClient.metadata(YouTubeDraft(title: "T", caption: "C"), publishAt: at, madeForKids: false, timeZone: zone)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        #expect(json["snippet"]?["title"] as? String == "T")
        #expect(json["snippet"]?["description"] as? String == "C")
        #expect(json["status"]?["privacyStatus"] as? String == "private")
        #expect(json["status"]?["publishAt"] as? String == "2026-11-02T06:00:00+07:00")
        #expect(json["status"]?["selfDeclaredMadeForKids"] as? Bool == false)
    }
}

struct YouTubeAuthTests {
    @Test func theBrowsersRedirectIsRead() {
        #expect(OAuthRedirect.parse(requestLine: "GET /?state=s&code=4/abc HTTP/1.1", expectedState: "s") == .code("4/abc"))
        #expect(OAuthRedirect.parse(requestLine: "GET /?state=s&error=access_denied HTTP/1.1", expectedState: "s") == .denied("access_denied"))
    }

    @Test func aRedirectFromSomewhereElseIsIgnored() {
        #expect(OAuthRedirect.parse(requestLine: "GET /?state=other&code=x HTTP/1.1", expectedState: "s") == .ignored)
        #expect(OAuthRedirect.parse(requestLine: "GET /favicon.ico HTTP/1.1", expectedState: "s") == .ignored)
        #expect(OAuthRedirect.parse(requestLine: "", expectedState: "s") == .ignored)
    }

    @Test func theListenerOnThisMacReceivesTheRedirect() async throws {
        let loopback = try OAuthLoopback(expectedState: "s")
        defer { loopback.stop() }
        let port = try await loopback.start()
        #expect(port > 0)
        async let redirect = loopback.redirect()
        // A stray request first, as browsers make for the page icon; the wait goes on.
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        let (page, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?state=s&code=abc")!)
        #expect(String(decoding: page, as: UTF8.self).contains("connected"))
        #expect(try await redirect == .code("abc"))
    }

    @Test func pkceMatchesTheStandardExample() {
        // RFC 7636, appendix B.
        #expect(OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = OAuthPKCE.verifier()
        #expect((43...128).contains(verifier.count))
        #expect(verifier != OAuthPKCE.verifier())
    }

    @Test func theSignInAddressAsksOnlyForWhatItNeeds() throws {
        let url = try #require(YouTubeAccount.authorizationURL(clientID: "id", redirectURI: "http://127.0.0.1:5000", state: "s", challenge: "c"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("scope") == "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly")
        #expect(value("redirect_uri") == "http://127.0.0.1:5000")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("access_type") == "offline")
    }

    @Test func googlesClientFileIsRead() {
        let json = #"{"installed":{"client_id":"a.apps.googleusercontent.com","client_secret":"b"}}"#
        let client = YouTubeCredentials.parseClientFile(Data(json.utf8))
        #expect(client?.id == "a.apps.googleusercontent.com" && client?.secret == "b")
        #expect(YouTubeCredentials.parseClientFile(Data("{}".utf8)) == nil)
    }
}

struct YouTubeErrorTests {
    private func body(_ reason: String) -> Data {
        Data(#"{"error":{"message":"Nope","errors":[{"reason":"\#(reason)"}]}}"#.utf8)
    }

    @Test func limitsMeanWaitingNotFailing() {
        for reason in ["quotaExceeded", "uploadLimitExceeded", "dailyLimitExceeded", "rateLimitExceeded"] {
            #expect(YouTubeError.from(status: 403, data: body(reason)) == .dailyLimit, "\(reason)")
        }
    }

    @Test func otherErrorsKeepGooglesMessage() {
        #expect(YouTubeError.from(status: 400, data: body("invalidPublishAt")) == .api(status: 400, reason: "invalidPublishAt", message: "Nope"))
        #expect(YouTubeError.from(status: 401, data: Data()) == .signInExpired)
    }

    @Test func aResumePointIsRead() {
        #expect(YouTubeClient.nextOffset(rangeHeader: "bytes=0-999") == 1000)
        #expect(YouTubeClient.nextOffset(rangeHeader: nil) == 0)
    }
}

// MARK: - The upload itself, against a stand-in for YouTube

/// Accepts chunks like YouTube does, and can fail on command.
private final class FakeYouTube: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var received = 0
    nonisolated(unsafe) private static var total = 0
    nonisolated(unsafe) private static var failNextChunks = 0
    nonisolated(unsafe) static var log: [String] = []
    private static let lock = NSLock()

    static func reset(total: Int, failNextChunks: Int) {
        lock.lock(); defer { lock.unlock() }
        received = 0
        self.total = total
        self.failNextChunks = failNextChunks
        log = []
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fake.youtube.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func bodyLength() -> Int {
        if let data = request.httpBody { return data.count }
        guard let stream = request.httpBodyStream else { return 0 }
        stream.open()
        defer { stream.close() }
        var length = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            length += n
        }
        return length
    }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
        let length = bodyLength()
        Self.lock.lock()
        Self.log.append(range)
        var status = 308
        var payload = Data()
        if range.hasPrefix("bytes */") {
            // A status query: just report what has arrived.
        } else if Self.failNextChunks > 0 {
            Self.failNextChunks -= 1
            status = 503
        } else {
            Self.received += length
            if Self.received >= Self.total {
                status = 201
                payload = Data(#"{"id":"video123"}"#.utf8)
            }
        }
        let headers = status == 308 && Self.received > 0 ? ["Range": "bytes=0-\(Self.received - 1)"] : [:]
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct YouTubeUploadTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeYouTube.self]
        return URLSession(configuration: configuration)
    }

    private func file(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "anyclip-upload-\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: size).write(to: url)
        return url
    }

    private let address = URL(string: "https://fake.youtube.test/session")!

    @Test func aFileGoesUpInChunks() async throws {
        let size = YouTubeClient.chunkSize * 2 + 1000
        let url = try file(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        FakeYouTube.reset(total: size, failNextChunks: 0)
        let id = try await YouTubeClient.sendFile(url, to: address, token: { "t" }, session: session()) { _ in }
        #expect(id == "video123")
        #expect(FakeYouTube.log == ["bytes 0-\(YouTubeClient.chunkSize - 1)/\(size)",
                                    "bytes \(YouTubeClient.chunkSize)-\(YouTubeClient.chunkSize * 2 - 1)/\(size)",
                                    "bytes \(YouTubeClient.chunkSize * 2)-\(size - 1)/\(size)"])
    }

    @Test func aServerErrorResumesWhereItStopped() async throws {
        let size = 5000
        let url = try file(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        FakeYouTube.reset(total: size, failNextChunks: 1)
        let id = try await YouTubeClient.sendFile(url, to: address, token: { "t" }, session: session()) { _ in }
        #expect(id == "video123")
        #expect(FakeYouTube.log == ["bytes 0-4999/5000", "bytes */5000", "bytes 0-4999/5000"])
    }

    @Test func anEmptyFileIsRefused() async throws {
        let url = try file(size: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) {
            _ = try await YouTubeClient.sendFile(url, to: address, token: { "t" }, session: session()) { _ in }
        }
    }
}
