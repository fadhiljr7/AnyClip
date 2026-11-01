//
//  Project.swift
//  AnyClip
//

import Foundation
import SwiftData

nonisolated enum ProjectStatus: String, Codable, Sendable {
    case queued, downloading, transcribing, analyzing, framing, ready, failed, cancelled

    var isWorking: Bool {
        switch self {
        case .queued, .downloading, .transcribing, .analyzing, .framing: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .queued: String(localized: "Waiting in queue")
        case .downloading: String(localized: "Downloading")
        case .transcribing: String(localized: "Transcribing")
        case .analyzing: String(localized: "Finding moments")
        case .framing: String(localized: "Tracking faces")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

/// Where a project's transcript comes from.
nonisolated enum TranscriptionMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, youtube, subtitleFile, whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: String(localized: "Apple Speech Recognition")
        case .youtube: String(localized: "YouTube Transcript")
        case .subtitleFile: String(localized: "Upload SRT or VTT")
        case .whisper: String(localized: "WhisperKit")
        }
    }

    var symbol: String {
        switch self {
        case .apple: "waveform"
        case .youtube: "captions.bubble"
        case .subtitleFile: "doc.text"
        case .whisper: "waveform.badge.magnifyingglass"
        }
    }

    var summary: String {
        switch self {
        case .apple: String(localized: "Built into macOS and ready to use. Listens to the video on this Mac — nothing is uploaded, and there’s nothing to download.")
        case .youtube: String(localized: "Fastest for YouTube links: uses the video’s own transcript, so there’s nothing to listen to. Check that the video has a transcript — on YouTube, open the description and look for Show Transcript.")
        case .subtitleFile: String(localized: "Use subtitles you already have, such as an .srt or .vtt file exported from your editor. Captions will match your file exactly.")
        case .whisper: String(localized: "OpenAI’s Whisper running on this Mac. Often more accurate, especially for Indonesian and mixed languages. The model is downloaded once, then works offline.")
        }
    }
}

/// Options chosen when a project is created. Stored with the project so a
/// re-run produces the same kind of clips.
nonisolated struct ProjectOptions: Codable, Hashable, Sendable {
    var clipCount = 5
    var length: ClipLength = .auto
    var aspect: AspectRatio = .vertical
    var faceTracking = true
    var captionPresetID = "bold"
    var hookEnabled = true
    /// BCP-47 code or "auto".
    var language = "auto"
    var exportWhenDone = false
    /// Optional focus, e.g. "funny moments about money".
    var topic = ""
    var transcription: TranscriptionMethod = .apple
    /// The YouTube transcript the user picked (yt-dlp's key, e.g. "en" or "id-orig"); nil picks automatically.
    var transcriptLanguage: String?
    /// Adds B-roll cards to each clip.
    var broll = true
    /// Stacks two speakers one above the other in clips where both are on screen.
    var stacked = false

    init() {}

    // Options saved by earlier versions lack newer keys, so every key is optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectOptions()
        clipCount = try c.decodeIfPresent(Int.self, forKey: .clipCount) ?? d.clipCount
        length = try c.decodeIfPresent(ClipLength.self, forKey: .length) ?? d.length
        aspect = try c.decodeIfPresent(AspectRatio.self, forKey: .aspect) ?? d.aspect
        faceTracking = try c.decodeIfPresent(Bool.self, forKey: .faceTracking) ?? d.faceTracking
        captionPresetID = try c.decodeIfPresent(String.self, forKey: .captionPresetID) ?? d.captionPresetID
        hookEnabled = try c.decodeIfPresent(Bool.self, forKey: .hookEnabled) ?? d.hookEnabled
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        exportWhenDone = try c.decodeIfPresent(Bool.self, forKey: .exportWhenDone) ?? d.exportWhenDone
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? d.topic
        transcription = (try? c.decodeIfPresent(TranscriptionMethod.self, forKey: .transcription)) ?? d.transcription
        transcriptLanguage = try c.decodeIfPresent(String.self, forKey: .transcriptLanguage)
        broll = try c.decodeIfPresent(Bool.self, forKey: .broll) ?? d.broll
        stacked = try c.decodeIfPresent(Bool.self, forKey: .stacked) ?? d.stacked
    }
}

@Model
final class Project {
    var id: UUID = UUID()
    var title: String = ""
    var sourceURL: String?
    var createdAt: Date = Date()
    var duration: Double = 0
    var language: String = ""
    var channel: String = ""
    var statusRaw: String = ProjectStatus.queued.rawValue
    var progress: Double = 0
    var statusDetail: String = ""
    var errorMessage: String?
    var optionsData: Data = Data()
    /// Relative to `AppPaths.projects`.
    var folderName: String = ""
    var videoFileName: String = ""
    var audioFileName: String?
    var momentSource: String = ""
    /// Explains a fallback, e.g. when the chosen AI provider failed.
    var momentNotice: String?
    /// Where the transcript came from, e.g. "YouTube transcript".
    var transcriptSource: String = ""
    /// Explains a transcription fallback, e.g. when a video had no YouTube transcript.
    var transcriptNotice: String?

    @Relationship(deleteRule: .cascade, inverse: \Clip.project)
    var clips: [Clip] = []

    init(title: String, sourceURL: String?, options: ProjectOptions) {
        self.id = UUID()
        self.title = title
        self.sourceURL = sourceURL
        self.optionsData = (try? JSONEncoder().encode(options)) ?? Data()
        self.folderName = id.uuidString
    }

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var options: ProjectOptions {
        get { (try? JSONDecoder().decode(ProjectOptions.self, from: optionsData)) ?? ProjectOptions() }
        set { optionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var folder: URL { AppPaths.projects.appending(path: folderName, directoryHint: .isDirectory) }
    var videoURL: URL? { videoFileName.isEmpty ? nil : folder.appending(path: videoFileName) }
    var audioURL: URL? { audioFileName.map { folder.appending(path: $0) } }
    var thumbnailURL: URL { folder.appending(path: "poster.jpg") }
    var transcriptURL: URL { folder.appending(path: "transcript.json") }

    var sortedClips: [Clip] { clips.sorted { $0.index < $1.index } }
}

@Model
final class Clip {
    var id: UUID = UUID()
    var index: Int = 0
    var start: Double = 0
    var end: Double = 0
    var title: String = ""
    var hook: String = ""
    var summary: String = ""
    var categoryRaw: String = ClipCategory.story.rawValue
    var score: Double = 0
    var isSaved: Bool = false
    var createdAt: Date = Date()
    var aspectRaw: String = AspectRatio.vertical.rawValue
    var keyframesData: Data = Data()
    var captionStyleData: Data = Data()
    var hookStyleData: Data = Data()
    /// Caption words edited by the user; nil means "use the transcript".
    var editedWordsData: Data?
    /// Source-time span the edited words replace.
    var editedFrom: Double = 0
    var editedTo: Double = 0
    var exportedPath: String?
    var exportedAt: Date?
    /// The exported cover image, the first frame of the exported video.
    var exportedThumbnailPath: String?
    var revision: Int = 0
    var brollData: Data = Data()
    var brollEnabled: Bool = true
    var teaserData: Data = Data()
    var teaserEnabled: Bool = false
    /// Faces and camera cuts seen by face tracking; empty for clips made before it was kept.
    var shotsData: Data = Data()
    /// The two-speaker stacked layout is on. It only takes effect where both speakers are in frame.
    var stackedLayout: Bool = false
    /// Shows the speaker on the right of the source in the top panel instead of the one on the left.
    var stackSwapped: Bool = false

    var project: Project?

    init(index: Int, candidate: MomentCandidate, aspect: AspectRatio, caption: CaptionStyle, hook: HookStyle) {
        self.id = UUID()
        self.index = index
        self.start = candidate.start
        self.end = candidate.end
        self.title = candidate.title
        self.hook = candidate.hook
        self.summary = candidate.summary
        self.categoryRaw = candidate.category.rawValue
        self.score = candidate.score
        self.aspectRaw = aspect.rawValue
        self.captionStyle = caption
        self.hookStyle = hook
    }

    var duration: Double { max(0, end - start) }
    var isHot: Bool { score >= 8 }

    var category: ClipCategory {
        get { ClipCategory(rawValue: categoryRaw) ?? .story }
        set { categoryRaw = newValue.rawValue }
    }

    var aspect: AspectRatio {
        get { AspectRatio(rawValue: aspectRaw) ?? .vertical }
        set { aspectRaw = newValue.rawValue }
    }

    var keyframes: [FrameKeyframe] {
        get { (try? JSONDecoder().decode([FrameKeyframe].self, from: keyframesData)) ?? [] }
        set { keyframesData = (try? JSONEncoder().encode(newValue.sorted { $0.time < $1.time })) ?? Data() }
    }

    var captionStyle: CaptionStyle {
        get { (try? JSONDecoder().decode(CaptionStyle.self, from: captionStyleData)) ?? CaptionStyle() }
        set { captionStyleData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var hookStyle: HookStyle {
        get { (try? JSONDecoder().decode(HookStyle.self, from: hookStyleData)) ?? HookStyle() }
        set { hookStyleData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var broll: [BRollInsert] {
        get { (try? JSONDecoder().decode([BRollInsert].self, from: brollData)) ?? [] }
        set { brollData = (try? JSONEncoder().encode(newValue.sorted { $0.time < $1.time })) ?? Data() }
    }

    var teaser: TeaserPlan {
        get { (try? JSONDecoder().decode(TeaserPlan.self, from: teaserData)) ?? TeaserPlan() }
        set { teaserData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// The teaser that plays before the clip, or nil when it's off, not chosen yet, or trimmed away.
    var activeTeaser: ClipSegment? {
        guard teaserEnabled else { return nil }
        let plan = teaser
        guard plan.selectedID != nil, plan.end - plan.start >= 0.5,
              plan.start >= start - 0.05, plan.end <= end + 0.05 else { return nil }
        return ClipSegment(start: max(plan.start, start), end: min(plan.end, end))
    }

    /// True when a chosen teaser no longer fits inside the trimmed clip.
    var teaserOutsideTrim: Bool {
        let plan = teaser
        return teaserEnabled && plan.selectedID != nil && activeTeaser == nil
    }

    var shots: ShotAnalysis? {
        get { shotsData.isEmpty ? nil : try? JSONDecoder().decode(ShotAnalysis.self, from: shotsData) }
        set { shotsData = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data() }
    }

    /// Whether both speakers appear in this clip's current trim; nil when the clip was never analysed.
    var twoSpeaker: StackSuitability? {
        shots.map { TwoSpeaker.suitability($0, range: ClipSegment(start: start, end: end)) }
    }

    /// True when the trim reaches more than a second past the part face tracking looked at.
    var shotsOutsideTrim: Bool {
        guard let analyzed = shots?.analyzed else { return false }
        return start < analyzed.start - 1 || end > analyzed.end + 1
    }

    /// The layout plan used for rendering, or nil for the ordinary full-frame layout. Stacking needs the 9:16 format
    /// and a clip where both speakers are on screen for a meaningful part of the time.
    var stackPlan: [LayoutSegment]? {
        guard stackedLayout, aspect == .vertical, let shots else { return nil }
        let range = ClipSegment(start: start, end: end)
        guard TwoSpeaker.suitability(shots, range: range).allowsStacking else { return nil }
        let plan = TwoSpeaker.segments(shots, range: range)
        guard plan.contains(where: \.isStacked) else { return nil }
        return stackSwapped ? plan.map(\.swapped) : plan
    }

    /// Turns the stacked layout on or off. Captions move to the seam between the speakers while it's on, and back to
    /// the preset's place when it's turned off, unless the user has moved them since.
    func setStacked(_ on: Bool) {
        guard on != stackedLayout else { return }
        stackedLayout = on
        var style = captionStyle
        let presetY = CaptionPreset.preset(style.presetID).style.positionY
        if on, style.positionY == presetY {
            style.positionY = TwoSpeaker.seamCaptionY
        } else if !on, style.positionY == TwoSpeaker.seamCaptionY {
            style.positionY = presetY
        }
        captionStyle = style
    }

    var editedWords: [Word]? {
        get { editedWordsData.flatMap { try? JSONDecoder().decode([Word].self, from: $0) } }
        set { editedWordsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var exportedURL: URL? {
        guard let exportedPath, FileManager.default.fileExists(atPath: exportedPath) else { return nil }
        return URL(filePath: exportedPath)
    }

    var exportedThumbnailURL: URL? {
        guard let exportedThumbnailPath, FileManager.default.fileExists(atPath: exportedThumbnailPath) else { return nil }
        return URL(filePath: exportedThumbnailPath)
    }

    var thumbnailURL: URL? { project.map { $0.folder.appending(path: "clip-\(id.uuidString).jpg") } }

    /// Caption words for the current trim, in source time.
    func captionWords(transcript: Transcript?) -> [Word] {
        let range = start...end
        let original = transcript?.words(in: range) ?? []
        guard let edited = editedWords else { return original }
        let kept = original.filter { $0.end <= editedFrom || $0.start >= editedTo }
        let inRange = edited.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        return (kept + inRange).sorted { $0.start < $1.start }
    }

    /// Replaces the words of one caption chunk with new text, spreading the timing evenly.
    func replaceCaption(_ chunk: [Word], with text: String, transcript: Transcript?) {
        guard let first = chunk.first, let last = chunk.last else { return }
        var words = captionWords(transcript: transcript)
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let span = max(last.end - first.start, 0.1)
        let step = span / Double(max(tokens.count, 1))
        let replacement = tokens.enumerated().map { i, t in
            Word(text: t, start: first.start + Double(i) * step, end: first.start + Double(i + 1) * step)
        }
        words.removeAll { $0.start >= first.start - 0.001 && $0.end <= last.end + 0.001 }
        words += replacement
        words.sort { $0.start < $1.start }
        editedFrom = min(editedWords == nil ? start : editedFrom, start)
        editedTo = max(editedWords == nil ? end : editedTo, end)
        editedWords = words
    }

    func markChanged() { revision += 1 }
}
