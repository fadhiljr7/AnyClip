//
//  YouTubeClient.swift
//  AnyClip
//
//  YouTube Data API calls: a resumable video upload, its thumbnail and the
//  connected channel's name. Tokens come from the caller and are never logged.
//

import Foundation

nonisolated enum YouTubeError: LocalizedError, Equatable {
    case notConnected
    case notConfigured
    case signInExpired
    case dailyLimit
    case sessionExpired
    case scheduleTimePassed
    case signInCancelled
    case signInDenied(String)
    case api(status: Int, reason: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Connect your YouTube account in Settings › YouTube first.")
        case .notConfigured: String(localized: "Add your Google client ID in Settings › YouTube first.")
        case .signInExpired: String(localized: "YouTube sign-in has expired. Connect your account again in Settings › YouTube.")
        case .dailyLimit: String(localized: "YouTube’s daily upload limit has been reached.")
        case .sessionExpired: String(localized: "YouTube ended the upload session.")
        case .scheduleTimePassed: String(localized: "The scheduled time has already passed. Choose a new time and schedule this clip again.")
        case .signInCancelled: String(localized: "Sign-in was cancelled.")
        case .signInDenied(let reason): String(localized: "Google didn’t allow the connection: \(reason)")
        case .api(let status, _, let message): String(localized: "YouTube answered with an error (\(status)): \(message)")
        }
    }

    /// Reads Google's error body. Upload and quota limits share one case, since the answer to both is waiting.
    static func from(status: Int, data: Data) -> YouTubeError {
        struct Body: Decodable {
            struct Inner: Decodable {
                struct Item: Decodable { let reason: String? }
                let message: String?
                let errors: [Item]?
            }
            let error: Inner?
        }
        let inner = (try? JSONDecoder().decode(Body.self, from: data))?.error
        let reason = inner?.errors?.first?.reason ?? ""
        if ["quotaExceeded", "dailyLimitExceeded", "uploadLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded"].contains(reason) {
            return .dailyLimit
        }
        if status == 401 { return .signInExpired }
        let message = inner?.message ?? String(decoding: data.prefix(300), as: UTF8.self)
        return .api(status: status, reason: reason, message: message)
    }
}

nonisolated enum YouTubeClient {
    /// Chunks must be a multiple of 256 KB. A failed chunk costs at most this much.
    static let chunkSize = 32 * 256 * 1024
    private static let maxRetries = 6
    private static let base = "https://www.googleapis.com"

    typealias TokenProvider = @Sendable () async throws -> String

    // MARK: Requests

    /// The video resource for a scheduled upload: private until YouTube publishes it at `publishAt`.
    static func metadata(_ draft: YouTubeDraft, publishAt: Date, madeForKids: Bool, timeZone: TimeZone = .current) throws -> Data {
        let resource: [String: Any] = [
            "snippet": ["title": draft.title, "description": draft.description, "categoryId": "22"],
            "status": ["privacyStatus": "private",
                       "publishAt": YouTubeTime.publishAt(publishAt, timeZone: timeZone),
                       "selfDeclaredMadeForKids": madeForKids],
        ]
        return try JSONSerialization.data(withJSONObject: resource)
    }

    /// Starts a resumable upload and returns the address to send the file to.
    static func startUpload(metadata: Data, fileSize: Int, token: String, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: URL(string: "\(base)/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue("video/*", forHTTPHeaderField: "X-Upload-Content-Type")
        request.httpBody = metadata
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, let location = http?.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw YouTubeError.from(status: http?.statusCode ?? 0, data: data)
        }
        return url
    }

    /// Sends a file in chunks, picking up from what YouTube has after any interruption. Returns the new video's ID.
    static func sendFile(_ file: URL, to uploadURL: URL, token: TokenProvider, session: URLSession = .shared,
                         progress: @Sendable (Double) -> Void) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        guard total > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var offset = 0
        var failures = 0
        while true {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            request.setValue("video/*", forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(offset)-\(offset + chunk.count - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            do {
                let (data, response) = try await session.upload(for: request, from: chunk)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200, 201:
                    progress(1)
                    return try videoID(in: data)
                case 308:
                    offset = nextOffset(rangeHeader: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"))
                    failures = 0
                    progress(Double(offset) / Double(total))
                case 500, 502, 503, 504:
                    failures += 1
                    guard failures <= maxRetries else { throw YouTubeError.from(status: status, data: data) }
                    try await wait(attempt: failures)
                    offset = try await receivedOffset(uploadURL, total: total, token: token, session: session)
                case 404, 410:
                    throw YouTubeError.sessionExpired
                default:
                    throw YouTubeError.from(status: status, data: data)
                }
            } catch let error as URLError where error.code != .cancelled {
                failures += 1
                guard failures <= maxRetries else { throw error }
                engineLog("YouTube upload interrupted (\(error.code.rawValue)), retrying")
                try await wait(attempt: failures)
                if let resumed = try? await receivedOffset(uploadURL, total: total, token: token, session: session) { offset = resumed }
            }
        }
    }

    /// Asks how much of the file YouTube already has.
    private static func receivedOffset(_ uploadURL: URL, total: Int, token: TokenProvider, session: URLSession) async throws -> Int {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 308: return nextOffset(rangeHeader: http?.value(forHTTPHeaderField: "Range"))
        case 404, 410: throw YouTubeError.sessionExpired
        default: throw YouTubeError.from(status: http?.statusCode ?? 0, data: data)
        }
    }

    /// "bytes=0-999" means the next byte to send is 1000; no header means nothing has arrived.
    static func nextOffset(rangeHeader: String?) -> Int {
        guard let last = rangeHeader?.split(separator: "-").last, let value = Int(last) else { return 0 }
        return value + 1
    }

    private static func wait(attempt: Int) async throws {
        try await Task.sleep(for: .seconds(min(pow(2, Double(attempt)), 60)))
    }

    private static func videoID(in data: Data) throws -> String {
        struct Video: Decodable { let id: String }
        return try JSONDecoder().decode(Video.self, from: data).id
    }

    /// Sets a video's custom thumbnail from a JPEG or PNG.
    static func setThumbnail(_ file: URL, videoID: String, token: String, session: URLSession = .shared) async throws {
        var components = URLComponents(string: "\(base)/upload/youtube/v3/thumbnails/set")!
        components.queryItems = [URLQueryItem(name: "videoId", value: videoID), URLQueryItem(name: "uploadType", value: "media")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(file.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YouTubeError.from(status: status, data: data) }
        engineLog("thumbnails.set \(videoID): HTTP \(status) \(String(decoding: data.prefix(400), as: UTF8.self))")
    }

    /// The name of the channel the token belongs to.
    static func channelName(token: String, session: URLSession = .shared) async throws -> String {
        struct Reply: Decodable {
            struct Item: Decodable {
                struct Snippet: Decodable { let title: String }
                let snippet: Snippet
            }
            let items: [Item]?
        }
        var request = URLRequest(url: URL(string: "\(base)/youtube/v3/channels?part=snippet&mine=true")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw YouTubeError.from(status: status, data: data) }
        return try JSONDecoder().decode(Reply.self, from: data).items?.first?.snippet.title ?? ""
    }
}
