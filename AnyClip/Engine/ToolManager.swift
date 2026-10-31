//
//  ToolManager.swift
//  AnyClip
//
//  Finds or installs the command-line helpers used for URL downloads.
//  Nothing here is required for local files.
//

import CryptoKit
import Foundation
import Observation

nonisolated enum ToolError: LocalizedError {
    case checksumMismatch(String)
    case noChecksum(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let file): String(localized: "\(file) didn’t match its published checksum, so it wasn’t installed. Try again later.")
        case .noChecksum(let file): String(localized: "The published checksum for \(file) couldn’t be found, so it wasn’t installed. Try again later.")
        }
    }
}

/// Checks a downloaded tool against the checksum its project publishes with each release.
nonisolated enum ToolChecksum {
    /// The hash listed for `file` in a `sha256sum`-style list ("<hash>  <name>" per line).
    static func expected(for file: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[1].drop(while: { $0 == "*" }) == file else { continue }
            let hash = parts[0].lowercased()
            if hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ file: URL, name: String, list: String) throws {
        guard let expected = expected(for: name, in: list) else { throw ToolError.noChecksum(name) }
        guard try sha256(of: file) == expected else { throw ToolError.checksumMismatch(name) }
    }
}

nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case ytDlp = "yt-dlp"
    case deno
    case ffmpeg

    var id: String { rawValue }

    var purpose: String {
        switch self {
        case .ytDlp: String(localized: "Downloads videos from YouTube, TikTok, Instagram and 1,000+ sites.")
        case .deno: String(localized: "JavaScript runtime that yt-dlp needs for YouTube.")
        case .ffmpeg: String(localized: "Optional. Converts unusual formats (WebM, AV1) when a site offers nothing else.")
        }
    }

    var canInstall: Bool { self != .ffmpeg }
}

nonisolated enum ToolPaths {
    static let systemDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static var searchPath: String {
        ([AppPaths.tools.path(percentEncoded: false)] + systemDirs + [NSHomeDirectory() + "/.deno/bin"]).joined(separator: ":")
    }

    /// Our own copy wins so "Update" always affects the binary we run.
    static func locate(_ tool: Tool) -> URL? {
        let fm = FileManager.default
        let own = AppPaths.tools.appending(path: tool.rawValue)
        if fm.isExecutableFile(atPath: own.path(percentEncoded: false)) { return own }
        var dirs = systemDirs
        if tool == .deno { dirs.append(NSHomeDirectory() + "/.deno/bin") }
        for dir in dirs {
            let path = dir + "/" + tool.rawValue
            if fm.isExecutableFile(atPath: path) { return URL(filePath: path) }
        }
        return nil
    }
}

nonisolated struct ToolStatus: Sendable, Hashable {
    var path: String?
    var version: String?
    var isOwnCopy: Bool { path?.hasPrefix(AppPaths.tools.path(percentEncoded: false)) ?? false }
}

@MainActor
@Observable
final class ToolManager {
    static let shared = ToolManager()

    private(set) var status: [Tool: ToolStatus] = [:]
    private(set) var busy: Set<Tool> = []
    var lastError: String?
    /// Installs in progress. Projects started close together wait for the same download instead of
    /// writing the same file at once.
    private var installing: [Tool: Task<Void, Error>] = [:]

    func refresh() async {
        for tool in Tool.allCases {
            status[tool] = await Self.probe(tool)
        }
    }

    /// Makes sure the tools needed for URL downloads exist, installing them if needed.
    func ensureDownloadTools(onStatus: @escaping (String) -> Void) async throws {
        if ToolPaths.locate(.ytDlp) == nil {
            onStatus(String(localized: "Installing yt-dlp…"))
            try await install(.ytDlp)
        }
        if ToolPaths.locate(.deno) == nil {
            onStatus(String(localized: "Installing Deno…"))
            try? await install(.deno)   // yt-dlp still works for most non-YouTube sites without it
        }
    }

    func install(_ tool: Tool) async throws {
        guard tool.canInstall else { return }
        if let running = installing[tool] { return try await running.value }
        let task = Task {
            busy.insert(tool)
            defer {
                busy.remove(tool)
                installing[tool] = nil
            }
            do {
                try await Self.download(tool)
                status[tool] = await Self.probe(tool)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                throw error
            }
        }
        installing[tool] = task
        try await task.value
    }

    /// yt-dlp breaks often when sites change; updating fixes most download errors.
    func update(_ tool: Tool) async throws {
        if tool == .ytDlp, let st = status[.ytDlp], st.isOwnCopy, let path = st.path {
            busy.insert(tool)
            defer { busy.remove(tool) }
            do {
                _ = try await ProcessRunner.run(URL(filePath: path), arguments: ["-U"])
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                throw error
            }
            status[tool] = await Self.probe(tool)
        } else {
            try await install(tool)
        }
    }

    func remove(_ tool: Tool) async {
        let own = AppPaths.tools.appending(path: tool.rawValue)
        try? FileManager.default.removeItem(at: own)
        status[tool] = await Self.probe(tool)
    }

    @concurrent
    private static func probe(_ tool: Tool) async -> ToolStatus {
        guard let url = ToolPaths.locate(tool) else { return ToolStatus() }
        let args = tool == .ffmpeg ? ["-version"] : ["--version"]
        let out = try? await ProcessRunner.run(url, arguments: args)
        let first = out?.split(separator: "\n").first.map(String.init)
        var version = first
        if tool == .ffmpeg, let first { version = first.split(separator: " ").dropFirst(2).first.map(String.init) }
        if tool == .deno, let first { version = first.replacing("deno ", with: "").split(separator: " ").first.map(String.init) }
        return ToolStatus(path: url.path(percentEncoded: false), version: version)
    }

    @concurrent
    private static func download(_ tool: Tool) async throws {
        let fm = FileManager.default
        let dest = AppPaths.tools.appending(path: tool.rawValue)
        switch tool {
        case .ytDlp:
            let asset = "yt-dlp_macos"
            let base = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
            let file = try await fetch(base + asset)
            defer { try? fm.removeItem(at: file) }
            try ToolChecksum.verify(file, name: asset, list: try await text(base + "SHA2-256SUMS"))
            try place(file, at: dest)
        case .deno:
            #if arch(arm64)
            let asset = "deno-aarch64-apple-darwin.zip"
            #else
            let asset = "deno-x86_64-apple-darwin.zip"
            #endif
            let base = "https://github.com/denoland/deno/releases/latest/download/"
            let zip = try await fetch(base + asset)
            defer { try? fm.removeItem(at: zip) }
            try ToolChecksum.verify(zip, name: asset, list: try await text(base + asset + ".sha256sum"))
            let unzipDir = fm.temporaryDirectory.appending(path: "deno-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: unzipDir) }
            _ = try await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"),
                                            arguments: ["-x", "-k", zip.path(percentEncoded: false), unzipDir.path(percentEncoded: false)])
            try place(unzipDir.appending(path: "deno"), at: dest)
        case .ffmpeg:
            break
        }
    }

    private nonisolated static func fetch(_ address: String) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: URL(string: address)!)
        try checkHTTP(response)
        return file
    }

    private nonisolated static func text(_ address: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: URL(string: address)!)
        try checkHTTP(response)
        return String(decoding: data, as: UTF8.self)
    }

    /// Makes the file executable, then swaps it in, so a failure leaves the tool that was there.
    private nonisolated static func place(_ file: URL, at dest: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        try AppPaths.replace(dest, with: file)
    }

    private nonisolated static func checkHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}
