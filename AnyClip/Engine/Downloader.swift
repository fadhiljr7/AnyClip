//
//  Downloader.swift
//  AnyClip
//
//  Fetches a video from a URL with yt-dlp. Video and audio are downloaded as
//  separate H.264 / AAC files when possible so AVFoundation can read them
//  without ffmpeg.
//

import Foundation
import AVFoundation

nonisolated struct RemoteVideoInfo: Sendable {
    var title: String
    var channel: String
    var duration: Double
    var language: String?
    var description: String
    /// Languages with captions uploaded by the creator.
    var subtitleLanguages: [String] = []
    /// Languages of YouTube's automatic captions in the spoken language (yt-dlp marks them `-orig`).
    var originalCaptionLanguages: [String] = []
}

/// A caption track chosen for a video.
nonisolated struct CaptionTrack: Sendable, Hashable {
    /// The key yt-dlp uses, e.g. `id-orig` or `en`.
    var key: String
    var automatic: Bool
    /// Plain language code, e.g. `id`.
    var language: String { key.replacingOccurrences(of: "-orig", with: "") }
}

nonisolated enum TranscriptError: LocalizedError {
    case notYouTube
    case noTranscript
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .notYouTube: String(localized: "YouTube Transcript only works with YouTube links.")
        case .noTranscript: String(localized: "This video doesn’t have a YouTube transcript.")
        case .emptyTranscript: String(localized: "The YouTube transcript couldn’t be read.")
        }
    }
}

nonisolated struct DownloadResult: Sendable {
    var info: RemoteVideoInfo
    var videoFile: URL
    /// Separate audio file, or nil when the video file carries audio.
    var audioFile: URL?
}

nonisolated enum DownloadError: LocalizedError {
    case noYtDlp
    case nothingDownloaded
    case unreadable
    case blocked

    var errorDescription: String? {
        switch self {
        case .blocked: String(localized: "The site refused the download. Try again in a minute, update yt-dlp in Settings › Downloads, or turn on browser cookies there.")
        case .noYtDlp: String(localized: "yt-dlp isn’t installed. Open Settings › Downloads to install it.")
        case .nothingDownloaded: String(localized: "The download finished but no video file was found.")
        case .unreadable: String(localized: "This video uses a format macOS can’t play. Install ffmpeg with Homebrew (brew install ffmpeg) and try again.")
        }
    }
}

nonisolated enum Downloader {
    static func cookieArgs() -> [String] {
        let browser = AppSettings.cookiesBrowser
        // The profile path after the colon isn't run through a shell, so nothing else would expand its "~".
        return browser.isEmpty ? [] : ["--cookies-from-browser", browser.replacingOccurrences(of: ":~/", with: ":" + NSHomeDirectory() + "/")]
    }

    /// Runs yt-dlp, retrying the transient 403s and resets YouTube hands out to some sessions.
    static func runWithRetry(_ ytdlp: URL, _ args: [String], onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await ProcessRunner.run(ytdlp, arguments: args, onLine: onLine)
            } catch let failure as ProcessFailure {
                attempt += 1
                let text = failure.output
                let transient = ["HTTP Error 403", "HTTP Error 5", "needs to be reloaded", "timed out", "Connection reset", "IncompleteRead"]
                    .contains { text.contains($0) }
                guard transient, attempt < 4 else {
                    if text.contains("HTTP Error 403") || text.contains("Sign in to confirm") { throw DownloadError.blocked }
                    throw failure
                }
                try await Task.sleep(for: .seconds(Double(attempt) * 2.5))
            }
        }
    }

    /// The full yt-dlp arguments for a link. The `--` keeps a link from ever being read as an option.
    static func arguments(_ options: [String], link: String) -> [String] {
        baseArgs() + options + ["--", link]
    }

    static func baseArgs() -> [String] {
        var args = ["--no-playlist", "--newline", "--no-warnings", "--no-mtime", "--no-part",
                    "--retries", "5", "--fragment-retries", "10", "--extractor-retries", "3"]
        if let deno = ToolPaths.locate(.deno) {
            args += ["--js-runtimes", "deno:" + deno.path(percentEncoded: false)]
        }
        if let ffmpeg = ToolPaths.locate(.ffmpeg) {
            args += ["--ffmpeg-location", ffmpeg.path(percentEncoded: false)]
        }
        return args + cookieArgs()
    }

    /// A YouTube video's title from YouTube's oEmbed endpoint: one small request, no yt-dlp. Used to name a
    /// project while it waits in the queue. Nil for other sites or when the request fails.
    @concurrent
    static func quickTitle(url: String) async -> String? {
        guard isYouTube(url), var endpoint = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        endpoint.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "format", value: "json")]
        struct Reply: Decodable { let title: String }
        guard let request = endpoint.url,
              let (data, response) = try? await URLSession.shared.data(from: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let title = try? JSONDecoder().decode(Reply.self, from: data).title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    @concurrent
    static func fetchInfo(url: String) async throws -> RemoteVideoInfo {
        guard let ytdlp = ToolPaths.locate(.ytDlp) else { throw DownloadError.noYtDlp }
        let out = try await runWithRetry(ytdlp, arguments(["-J", "--skip-download"], link: url))
        guard let start = out.firstIndex(of: "{"),
              let data = String(out[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.nothingDownloaded
        }
        return RemoteVideoInfo(
            title: (json["title"] as? String) ?? (json["fulltitle"] as? String) ?? url,
            channel: (json["uploader"] as? String) ?? (json["channel"] as? String) ?? "",
            duration: (json["duration"] as? Double) ?? Double((json["duration"] as? Int) ?? 0),
            language: json["language"] as? String,
            description: String(((json["description"] as? String) ?? "").prefix(600)),
            subtitleLanguages: ((json["subtitles"] as? [String: Any]) ?? [:]).keys
                .filter { $0 != "live_chat" }.sorted(),
            originalCaptionLanguages: ((json["automatic_captions"] as? [String: Any]) ?? [:]).keys
                .filter { $0.hasSuffix("-orig") }.sorted())
    }

    /// Whether a link is on one of these sites or a subdomain of one. "notyoutube.com" isn't on "youtube.com".
    static func isLink(_ link: String, onAnyOf domains: [String]) -> Bool {
        guard let host = URL(string: link)?.host(percentEncoded: false)?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isYouTube(_ link: String) -> Bool {
        isLink(link, onAnyOf: ["youtu.be", "youtube.com", "youtube-nocookie.com"])
    }

    /// Every transcript the video offers: YouTube's automatic captions in the spoken language, then
    /// the ones the creator uploaded. Machine translations are left out.
    static func captionTracks(in info: RemoteVideoInfo) -> [CaptionTrack] {
        info.originalCaptionLanguages.map { CaptionTrack(key: $0, automatic: true) }
            + info.subtitleLanguages.map { CaptionTrack(key: $0, automatic: false) }
    }

    /// Picks a transcript: the one the user chose, else the spoken language (from the user, YouTube or,
    /// failing both, the title and description), preferring automatic captions because they carry a
    /// timestamp for every word.
    static func captionTrack(in info: RemoteVideoInfo, language: String?, preferred: String? = nil) -> CaptionTrack? {
        let tracks = captionTracks(in: info)
        if let preferred, let chosen = tracks.first(where: { $0.key == preferred }) { return chosen }
        func base(_ code: String) -> String { String(code.split(separator: "-").first ?? Substring(code)).lowercased() }
        // When neither the user nor YouTube says what's spoken, ask which of the offered languages
        // the title and description are written in.
        let offered = Array(Set(tracks.map { base($0.key) }))
        let guessed = offered.count > 1
            ? SpeechEngine.detectLanguage(in: info.title + "\n" + info.description, among: offered) : nil
        for wanted in [language ?? info.language, guessed].compactMap({ $0 }).map(base) {
            if let match = tracks.first(where: { base($0.key) == wanted }) { return match }
        }
        return tracks.first(where: \.automatic) ?? tracks.first
    }

    /// Downloads a video's YouTube transcript as timed words.
    @concurrent
    static func youtubeTranscript(url: String, info: RemoteVideoInfo?, language: String?, preferred: String? = nil,
                                  into folder: URL) async throws -> (words: [Word], language: String) {
        guard isYouTube(url) else { throw TranscriptError.notYouTube }
        guard let ytdlp = ToolPaths.locate(.ytDlp) else { throw DownloadError.noYtDlp }
        let resolvedInfo: RemoteVideoInfo
        if let info { resolvedInfo = info } else { resolvedInfo = try await fetchInfo(url: url) }
        guard let track = captionTrack(in: resolvedInfo, language: language, preferred: preferred) else {
            throw TranscriptError.noTranscript
        }
        let prefix = "transcript"
        for old in files(in: folder, prefix: prefix) { try? FileManager.default.removeItem(at: old) }
        _ = try await runWithRetry(ytdlp, arguments([
            "--skip-download", track.automatic ? "--write-auto-subs" : "--write-subs",
            "--sub-format", "vtt", "--sub-langs", track.key,
            "-o", folder.appending(path: prefix).path(percentEncoded: false),
        ], link: url))
        guard let file = files(in: folder, prefix: prefix).first(where: { $0.pathExtension == "vtt" }),
              let text = try? String(contentsOf: file, encoding: .utf8) else { throw TranscriptError.noTranscript }
        let words = SubtitleParser.words(fromVTT: text)
        guard !words.isEmpty else { throw TranscriptError.emptyTranscript }
        return (words, track.language)
    }

    /// Downloads into `folder`. `progress` receives 0…1.
    @concurrent
    static func download(url: String, into folder: URL, maxHeight: Int = 1080,
                         progress: @Sendable @escaping (Double) -> Void) async throws -> DownloadResult {
        guard let ytdlp = ToolPaths.locate(.ytDlp) else { throw DownloadError.noYtDlp }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = try await fetchInfo(url: url)
        let hasFFmpeg = ToolPaths.locate(.ffmpeg) != nil

        // Pass 1 – video. Prefer H.264 video-only, then any MP4, then whatever exists.
        let h = maxHeight
        let videoSelector = "bv[vcodec^=avc1][height<=\(h)]/bv[ext=mp4][vcodec!^=av01][height<=\(h)]/b[ext=mp4][height<=\(h)]/bv[height<=\(h)]/b"
        _ = try await runWithRetry(ytdlp, arguments([
            "-f", videoSelector, "-o", folder.appending(path: "source-video.%(ext)s").path(percentEncoded: false),
        ], link: url)) { line in
            if let p = parsePercent(line) { progress(p * 0.85) }
        }
        guard var video = files(in: folder, prefix: "source-video").first else { throw DownloadError.nothingDownloaded }

        let asset = AVURLAsset(url: video)
        let videoPlayable = (try? await asset.load(.isPlayable)) ?? false
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty

        var audio: URL?
        if !hasAudio || !videoPlayable {
            // Pass 2 – audio, AAC when available. A video can be used without it, so only Stop ends the project here.
            do {
                _ = try await runWithRetry(ytdlp, arguments([
                    "-f", "ba[ext=m4a]/ba[acodec^=mp4a]/ba", "-o", folder.appending(path: "source-audio.%(ext)s").path(percentEncoded: false),
                ], link: url)) { line in
                    if let p = parsePercent(line) { progress(0.85 + p * 0.15) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                engineLog("audio download failed: \(error)")
            }
            audio = files(in: folder, prefix: "source-audio").first
        }

        if !videoPlayable {
            guard hasFFmpeg else { throw DownloadError.unreadable }
            video = try await Transcode.toH264(video, in: folder)
        }
        if let a = audio, !((try? await AVURLAsset(url: a).load(.isPlayable)) ?? false) {
            audio = hasFFmpeg ? try await Transcode.toAAC(a, in: folder) : nil
        }
        progress(1)
        return DownloadResult(info: info, videoFile: video, audioFile: audio)
    }

    private static func files(in folder: URL, prefix: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) && !$0.lastPathComponent.hasSuffix(".json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func parsePercent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]"), let pct = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        return Double(line[pct].dropLast()).map { $0 / 100 }
    }
}

nonisolated enum Transcode {
    @concurrent
    static func toH264(_ input: URL, in folder: URL) async throws -> URL {
        guard let ffmpeg = ToolPaths.locate(.ffmpeg) else { throw DownloadError.unreadable }
        let out = folder.appending(path: "source-video-h264.mp4")
        _ = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-i", input.path(percentEncoded: false), "-map", "0:v:0", "-map", "0:a?",
            "-c:v", "h264_videotoolbox", "-b:v", "12M", "-c:a", "aac", "-b:a", "192k", out.path(percentEncoded: false),
        ])
        return out
    }

    @concurrent
    static func toAAC(_ input: URL, in folder: URL) async throws -> URL {
        guard let ffmpeg = ToolPaths.locate(.ffmpeg) else { throw DownloadError.unreadable }
        let out = folder.appending(path: "source-audio-aac.m4a")
        _ = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-i", input.path(percentEncoded: false), "-vn", "-c:a", "aac", "-b:a", "192k", out.path(percentEncoded: false),
        ])
        return out
    }
}

nonisolated enum SubtitleParser {
    private static let cueTiming = try! NSRegularExpression(pattern: #"(\d{1,2}:)?(\d{2}):(\d{2})\.(\d{3})\s+-->\s+(\d{1,2}:)?(\d{2}):(\d{2})\.(\d{3})"#)
    private static let wordStamp = try! NSRegularExpression(pattern: #"<(\d{2}):(\d{2}):(\d{2})\.(\d{3})>"#)

    /// Words from an SRT or VTT file in whatever text encoding it was saved in. Empty when nothing can be read.
    static func words(fromFile url: URL) -> [Word] {
        guard let data = try? Data(contentsOf: url), let text = decode(data) else { return [] }
        return words(fromSubtitles: text)
    }

    /// Words from SRT or VTT text; SRT differs by a comma in its timestamps and has no header.
    static func words(fromSubtitles text: String) -> [Word] {
        guard !text.contains("WEBVTT") else { return words(fromVTT: text) }
        return words(fromVTT: "WEBVTT\n\n" + text.replacingOccurrences(of: #"(\d{2}:\d{2}:\d{2}),(\d{3})"#, with: "$1.$2", options: .regularExpression))
    }

    /// Subtitle files are often not UTF-8: editors on Windows save UTF-16 or Windows-1252.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// Parses WebVTT. Uses inline `<00:00:01.230>` word stamps when present
    /// (YouTube auto captions), otherwise spreads words evenly over each cue.
    static func words(fromVTT text: String) -> [Word] {
        var words: [Word] = []
        let blocks = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
        let stampPattern = #"<\d{2}:\d{2}:\d{2}\.\d{3}>"#
        let fileHasStamps = text.range(of: stampPattern, options: .regularExpression) != nil
        let timing = cueTiming
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let tIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let tLine = lines[tIndex]
            guard let m = timing.firstMatch(in: tLine, range: NSRange(tLine.startIndex..., in: tLine)) else { continue }
            func num(_ i: Int) -> Double {
                guard let r = Range(m.range(at: i), in: tLine) else { return 0 }
                return Double(tLine[r].trimmingCharacters(in: CharacterSet(charactersIn: ":"))) ?? 0
            }
            let start = num(1) * 3600 + num(2) * 60 + num(3) + num(4) / 1000
            let end = num(5) * 3600 + num(6) * 60 + num(7) + num(8) / 1000
            let bodyLines = Array(lines[(tIndex + 1)...])
            if fileHasStamps {
                // Rolling captions repeat the previous line as plain text; only the stamped line is new.
                let stamped = bodyLines.filter { $0.range(of: stampPattern, options: .regularExpression) != nil }
                guard !stamped.isEmpty else { continue }
                words += stampedWords(stamped.joined(separator: " "), cueStart: start, cueEnd: end)
            } else {
                let body = bodyLines.joined(separator: " ")
                // Rolling caption repeats: only keep cues that add new text.
                let plain = stripTags(body)
                let tokens = plain.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !tokens.isEmpty else { continue }
                let step = (end - start) / Double(tokens.count)
                for (i, t) in tokens.enumerated() {
                    words.append(Word(text: t, start: start + Double(i) * step, end: start + Double(i + 1) * step))
                }
            }
        }
        // Remove duplicates from overlapping cues.
        var cleaned: [Word] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            if let last = cleaned.last, last.text == w.text, abs(last.start - w.start) < 0.05 { continue }
            if let last = cleaned.last, w.start < last.end { cleaned[cleaned.count - 1].end = max(last.start + 0.05, w.start) }
            cleaned.append(w)
        }
        return cleaned
    }

    private static func stampedWords(_ body: String, cueStart: Double, cueEnd: Double) -> [Word] {
        // Pattern: first word<00:00:01.230><c> second</c><00:00:01.500><c> third</c>
        var result: [Word] = []
        var currentStart = cueStart
        var remaining = Substring(body)
        let stamp = wordStamp
        var pieces: [(Double, String)] = []
        while true {
            let s = String(remaining)
            guard let m = stamp.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range, in: s) else {
                pieces.append((currentStart, s))
                break
            }
            pieces.append((currentStart, String(s[..<r.lowerBound])))
            func g(_ i: Int) -> Double { Double(s[Range(m.range(at: i), in: s)!]) ?? 0 }
            currentStart = g(1) * 3600 + g(2) * 60 + g(3) + g(4) / 1000
            remaining = Substring(s[r.upperBound...])
        }
        for (i, piece) in pieces.enumerated() {
            let text = stripTags(piece.1).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let end = i + 1 < pieces.count ? pieces[i + 1].0 : cueEnd
            let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let step = max(end - piece.0, 0.05) / Double(tokens.count)
            for (j, t) in tokens.enumerated() {
                result.append(Word(text: t, start: piece.0 + Double(j) * step, end: piece.0 + Double(j + 1) * step))
            }
        }
        return result
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
