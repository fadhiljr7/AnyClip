//
//  SecurityTests.swift
//  AnyClipTests
//
//  What AnyClip downloads and runs, where API keys go, and how they're kept.
//

import Testing
import Foundation
@testable import AnyClip

struct SecurityTests {
    @Test func aLinkIsNeverReadAsAnOption() throws {
        let args = Downloader.arguments(["-J"], link: "--exec=rm -rf ~")
        #expect(args.suffix(2) == ["--", "--exec=rm -rf ~"])
        let separator = try #require(args.firstIndex(of: "--"))
        let option = try #require(args.firstIndex(of: "-J"))
        #expect(separator > option)
    }

    @Test func sitesAreMatchedByWholeDomain() {
        #expect(Downloader.isYouTube("https://www.youtube.com/watch?v=x"))
        #expect(Downloader.isYouTube("https://youtu.be/x"))
        #expect(!Downloader.isYouTube("https://notyoutube.com/watch?v=x"))
        #expect(!Downloader.isYouTube("https://youtube.com.evil.example/watch?v=x"))
        #expect(LanguageList.looksLikeVideoLink("https://x.com/a/status/1"))
        #expect(!LanguageList.looksLikeVideoLink("https://netflix.com/title/1"))
    }

    @Test func apiKeysDontCrossTheInternetUnencrypted() {
        #expect(AIProvider.chatEndpoint(base: "http://api.example.com/v1") == nil)
        #expect(AIProvider.chatEndpoint(base: "https://api.example.com/v1") != nil)
        #expect(AIProvider.chatEndpoint(base: "http://localhost:11434/v1")?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(AIProvider.chatEndpoint(base: "http://127.0.0.1:1234/v1") != nil)
        #expect(AIProvider.chatEndpoint(base: "http://studio.local:1234/v1") != nil)
        #expect(AIProvider.chatEndpoint(base: "http://localhost.example.com/v1") == nil)
    }

    private let list = """
    0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa  yt-dlp_macos
    20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1  yt-dlp_macos.zip
    aaaa  short
    """

    @Test func theChecksumIsReadForExactlyThatFile() {
        #expect(ToolChecksum.expected(for: "yt-dlp_macos", in: list)?.hasPrefix("0f922c") == true)
        #expect(ToolChecksum.expected(for: "yt-dlp_macos.zip", in: list)?.hasPrefix("20d98f") == true)
        #expect(ToolChecksum.expected(for: "yt-dlp", in: list) == nil)
        #expect(ToolChecksum.expected(for: "short", in: list) == nil)
    }

    @Test func aDownloadThatDoesntMatchIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "anyclip-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        // SHA-256 of "abc".
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  tool"
        try ToolChecksum.verify(file, name: "tool", list: good)
        #expect(throws: ToolError.self) { try ToolChecksum.verify(file, name: "tool", list: list) }
        #expect(throws: ToolError.self) { try ToolChecksum.verify(file, name: "tool", list: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f200ffff  tool") }
    }

    @Test func theKeychainKeepsAndReplacesAKey() throws {
        let account = "anyclip-test-\(UUID().uuidString)"
        defer { Keychain.delete(account: account) }
        try Keychain.save("first", account: account)
        #expect(Keychain.read(account: account) == "first")
        try Keychain.save("second", account: account)
        #expect(Keychain.read(account: account) == "second")
        try Keychain.save("", account: account)
        #expect(Keychain.read(account: account) == nil)
    }
}
