//
//  TeaserSection.swift
//  AnyClip
//
//  Teaser (cold open) controls in the Hook inspector: turn it on, compare the
//  suggested moments, pick one, and move its cut points word by word.
//

import SwiftUI
import SwiftData

struct TeaserSection: View {
    @Bindable var clip: Clip
    let transcript: Transcript?
    let preview: PreviewController
    /// Called after the user picks a teaser, so the hook can be checked against it.
    var onChosen: () -> Void = {}
    /// Brings the hook title section into view.
    var onShowHook: () -> Void = {}
    @State private var thumbnails: [UUID: CGImage] = [:]

    private var finding: Bool { Studio.shared.isFindingTeasers(clip) }

    var body: some View {
        let plan = clip.teaser
        let error = Studio.shared.teaserErrors[clip.id]
        Section {
            Toggle("Start with a teaser", isOn: Binding(get: { clip.teaserEnabled }, set: setEnabled))
        } header: {
            Text("Teaser")
        } footer: {
            Text("Opens the video with a 2–3 second moment from later in the clip, then plays the clip from its start. The video gets that much longer.")
                .foregroundStyle(.secondary)
        }
        if clip.teaserEnabled {
            if plan.selectedID != nil { chosen(plan) }
            Section("Suggestions") {
                if finding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finding moments that make people stay…").foregroundStyle(.secondary)
                    }
                } else {
                    if let error {
                        WarningLabel(verbatim: error)
                    }
                    if let notice = plan.notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                    if plan.isStale(start: clip.start, end: clip.end) {
                        Label("You’ve trimmed the clip since these were suggested. Suggest Again to look at the new range.",
                              systemImage: "scissors")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(plan.candidates) { candidate in
                        TeaserRow(candidate: candidate, clipStart: clip.start, aspect: clip.aspect,
                                  isOutside: candidate.start < clip.start - 0.05 || candidate.end > clip.end + 0.05,
                                  thumbnail: thumbnails[candidate.id], isChosen: plan.selectedID == candidate.id,
                                  onPreview: { preview.play(sourceFrom: candidate.start, to: candidate.end) },
                                  onUse: { use(candidate) })
                    }
                }
                Button(plan.candidates.isEmpty && plan.notice == nil ? "Suggest Moments" : "Suggest Again", systemImage: "sparkles") { find() }
                    .disabled(finding)
                    .help("Asks the AI for new teaser moments from this clip. Your chosen teaser stays until you pick another.")
                if !plan.source.isEmpty {
                    Text("Suggested by \(plan.source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: plan.candidates.map(\.id)) { await loadThumbnails(plan.candidates) }
        }
    }

    // MARK: Chosen teaser

    @ViewBuilder
    private func chosen(_ plan: TeaserPlan) -> some View {
        let words = clip.captionWords(transcript: transcript)
        let range = wordRange(plan, words: words)
        Section("Chosen Teaser") {
            if clip.teaserOutsideTrim {
                WarningLabel("This moment is outside the trimmed clip, so the video starts without a teaser. Choose another moment.")
            } else {
                chosenDetails(plan, words: words, range: range)
            }
        }
    }

    @ViewBuilder
    private func chosenDetails(_ plan: TeaserPlan, words: [Word], range: ClosedRange<Int>?) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: range.map { "“\(words[$0].map(\.text).joined(separator: " "))”" } ?? "")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("From \(formatTimestamp(plan.start - clip.start)) in the clip · \(plan.end - plan.start, format: .number.precision(.fractionLength(1))) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if clip.hookStyle.enabled, let said = range.map({ words[$0].map(\.text).joined(separator: " ") }),
                   TeaserText.repeats(clip.hook, said) {
                    VStack(alignment: .leading, spacing: 2) {
                        WarningLabel("The hook title says the same thing as this teaser.")
                        Button("Show Hook Ideas", action: onShowHook)
                            .buttonStyle(.link)
                            .padding(.leading, 22)
                            .font(.caption)
                    }
                }
                if plan.start < clip.start + TeaserFinder.openingGuard {
                    WarningLabel("This is part of the clip’s opening, so viewers hear it twice in a row.")
                }
            }
            .padding(.vertical, 2)
            if let range {
                LabeledContent("Start") {
                    WordNudge(earlier: { adjust(words, range.lowerBound - 1, range.upperBound) },
                              later: { adjust(words, range.lowerBound + 1, range.upperBound) },
                              canEarlier: range.lowerBound > 0 && words[range.lowerBound - 1].start >= clip.start - 0.05,
                              canLater: range.lowerBound < range.upperBound)
                }
                LabeledContent("End") {
                    WordNudge(earlier: { adjust(words, range.lowerBound, range.upperBound - 1) },
                              later: { adjust(words, range.lowerBound, range.upperBound + 1) },
                              canEarlier: range.upperBound > range.lowerBound,
                              canLater: range.upperBound + 1 < words.count && words[range.upperBound + 1].end <= clip.end + 0.05)
                }
            }
            Button("Play Opening", systemImage: "play.fill") { preview.update(for: clip, playFromStart: true) }
                .help("Plays the video from the first frame: the teaser, then the clip.")
    }

    /// Indices of the words inside the chosen teaser.
    private func wordRange(_ plan: TeaserPlan, words: [Word]) -> ClosedRange<Int>? {
        TeaserText.wordRange(start: plan.start, end: plan.end, in: words)
    }

    private func adjust(_ words: [Word], _ lo: Int, _ hi: Int) {
        guard lo >= 0, hi < words.count, lo <= hi, let media = clip.project?.audioURL ?? clip.project?.videoURL else { return }
        let cut = TeaserText.cutPoints(words: words, range: lo...hi)
        Task {
            let snapped = await AudioSnap.refine(media: media, start: cut.start, end: cut.end, words: words)
            guard clip.modelContext != nil else { return }
            var plan = clip.teaser
            plan.start = snapped.start
            plan.end = snapped.end
            clip.teaser = plan
            preview.update(for: clip, playFromStart: true)
        }
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        clip.teaserEnabled = on
        let plan = clip.teaser
        if on, plan.candidates.isEmpty, plan.notice == nil { find() }
        preview.update(for: clip, playFromStart: on && clip.activeTeaser != nil)
    }

    private func use(_ candidate: TeaserCandidate) {
        var plan = clip.teaser
        plan.select(candidate)
        clip.teaser = plan
        preview.update(for: clip, playFromStart: true)
        onChosen()
    }

    private func find() {
        Studio.shared.refreshTeasers(for: clip)
    }

    private func loadThumbnails(_ candidates: [TeaserCandidate]) async {
        for c in candidates where thumbnails[c.id] == nil {
            guard var input = Studio.shared.renderInput(for: clip, shortSide: 240) else { return }
            input.start = c.start
            input.end = c.end
            input.teaser = nil
            if let image = try? await ClipExporter.frame(input, at: c.duration / 2, maxSize: CGSize(width: 180, height: 320)) {
                thumbnails[c.id] = image
            }
        }
    }
}

struct TeaserRow: View {
    let candidate: TeaserCandidate
    let clipStart: Double
    let aspect: AspectRatio
    /// The moment lies outside the clip as it's trimmed now.
    var isOutside = false
    let thumbnail: CGImage?
    let isChosen: Bool
    var onPreview: () -> Void
    var onUse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPreview) {
                ZStack {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.45), in: .circle)
                }
                .frame(width: 54, height: 54 / aspect.ratio)
                .clipShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(isOutside)
            .accessibilityLabel("Preview this moment")
            .help("Play this moment where it happens in the clip")

            VStack(alignment: .leading, spacing: 4) {
                Label(candidate.angle.title, systemImage: candidate.angle.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: "“\(candidate.text)”")
                    .fixedSize(horizontal: false, vertical: true)
                if isOutside {
                    Text("Outside the trimmed clip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("At \(formatTimestamp(candidate.start - clipStart)) · \(candidate.duration, format: .number.precision(.fractionLength(1))) s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !candidate.reason.isEmpty {
                    Text(candidate.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(candidate.warnings, id: \.self) { warning in
                    WarningLabel(verbatim: warning.message)
                }
                HStack {
                    Spacer()
                    if isChosen {
                        Label("In Use", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.tint)
                    } else {
                        Button("Use as Teaser", action: onUse)
                            .disabled(isOutside)
                            .help("Open the video with this moment and play it from the start")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Two small buttons that move a cut point one word earlier or later.
struct WordNudge: View {
    var earlier: () -> Void
    var later: () -> Void
    var canEarlier: Bool
    var canLater: Bool

    var body: some View {
        ControlGroup {
            Button("One Word Earlier", systemImage: "chevron.left", action: earlier)
                .disabled(!canEarlier)
                .help("Move one word earlier")
            Button("One Word Later", systemImage: "chevron.right", action: later)
                .disabled(!canLater)
                .help("Move one word later")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}
