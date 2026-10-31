//
//  AppSettings.swift
//  AnyClip
//
//  Every preference AnyClip keeps in UserDefaults: its key, its type and its
//  default, in one place. Views bind with `@AppStorage(AppSettings.Key.x)`.
//

import Foundation

nonisolated enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc
}

nonisolated enum AppSettings {
    enum Key {
        static let aiProvider = "aiProvider"
        static let allowPrivateCloud = "allowPCC"
        static let fallbackToApple = "fallbackToApple"
        static let cookiesBrowser = "cookiesBrowser"
        static let downloadHeight = "downloadHeight"
        static let exportFolder = "exportFolder"
        static let exportShortSide = "exportShortSide"
        static let videoCodec = "videoCodec"
        static let loopPreview = "loopPreview"
        static let settingsTab = "settingsTab"
        static let inspectorTab = "inspectorTab"
        static let lastOptions = "lastOptions"
        static let watermark = "watermark"
        static func aiModel(_ provider: AIProvider) -> String { "aiModel.\(provider.rawValue)" }
    }

    private static var defaults: UserDefaults { .standard }

    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    /// When a cloud provider fails, Apple Intelligence takes over instead of the work stopping.
    static var fallbackToApple: Bool { bool(Key.fallbackToApple, default: true) }
    static var allowPrivateCloud: Bool { bool(Key.allowPrivateCloud, default: true) }
    static var loopPreview: Bool { bool(Key.loopPreview, default: true) }

    static var videoCodec: VideoCodec {
        defaults.string(forKey: Key.videoCodec).flatMap(VideoCodec.init(rawValue:)) ?? .h264
    }

    /// Short side of exported clips, in pixels.
    static var exportShortSide: Double {
        let value = defaults.double(forKey: Key.exportShortSide)
        return value > 0 ? value : 1080
    }

    /// Tallest video downloaded from a site, in pixels.
    static var downloadHeight: Int {
        let value = defaults.integer(forKey: Key.downloadHeight)
        return value > 0 ? value : 1080
    }

    /// The browser yt-dlp borrows a sign-in from, in yt-dlp's own form; empty for none.
    static var cookiesBrowser: String { defaults.string(forKey: Key.cookiesBrowser) ?? "" }
}
