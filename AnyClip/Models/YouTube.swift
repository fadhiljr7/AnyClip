//
//  YouTube.swift
//  AnyClip
//
//  The rules behind scheduled YouTube uploads: when each clip goes out and what
//  YouTube is told about it. No networking here.
//

import Foundation

/// A clip's place in the upload queue, saved with the clip.
nonisolated enum YouTubeUploadState: String, Sendable {
    case queued, scheduled, failed
}

/// What Auto Schedule works from: the first video's time and the gap between videos.
nonisolated struct AutoSchedule: Sendable, Hashable {
    enum Unit: String, CaseIterable, Identifiable, Sendable {
        case minutes, hours, days
        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3600
            case .days: 86_400
            }
        }
    }

    /// YouTube needs time to spare, and the clip still has to be rendered and uploaded.
    static let minimumLeadTime: TimeInterval = 15 * 60

    var first: Date
    var every: Int
    var unit: Unit

    var interval: TimeInterval { TimeInterval(max(every, 1)) * unit.seconds }

    /// One publish time per video, in order.
    func times(count: Int) -> [Date] {
        (0..<max(count, 0)).map { first.addingTimeInterval(TimeInterval($0) * interval) }
    }

    func isInTime(now: Date = Date()) -> Bool { first >= now.addingTimeInterval(Self.minimumLeadTime) }

    /// The next whole hour at least an hour from now, in this time zone: a sensible first slot.
    static func suggestedFirst(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let later = now.addingTimeInterval(3600)
        let hour = calendar.dateInterval(of: .hour, for: later)?.start ?? later
        return hour < later ? hour.addingTimeInterval(3600) : hour
    }
}

/// Dates as this app shows them for uploads: the local time zone, always 24-hour.
nonisolated enum YouTubeTime {
    static func display(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    /// The value YouTube expects for `publishAt`, with the local UTC offset.
    static func publishAt(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Daily API quotas reset at midnight Pacific time.
    static func nextQuotaReset(after date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }
}

/// A video's title and description within what YouTube accepts.
nonisolated struct YouTubeDraft: Sendable, Hashable {
    static let maxTitleCharacters = 100
    static let maxDescriptionBytes = 5000

    var title: String
    var description: String

    init(title: String, caption: String) {
        let cleanTitle = Self.withoutAngleBrackets(title)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = cleanTitle.isEmpty ? String(localized: "Untitled clip") : String(cleanTitle.prefix(Self.maxTitleCharacters))
        var text = Self.withoutAngleBrackets(caption).trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf8.count > Self.maxDescriptionBytes { text.removeLast() }
        self.description = text
    }

    private static func withoutAngleBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
    }
}
