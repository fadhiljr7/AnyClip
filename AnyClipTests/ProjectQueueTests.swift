//
//  ProjectQueueTests.swift
//  AnyClipTests
//
//  Projects are made one at a time; the ones waiting their turn are named
//  before yt-dlp ever runs.
//

import Testing
import Foundation
@testable import AnyClip

struct ProjectQueueTests {
    @Test func aWaitingProjectCountsAsWorking() {
        // So it shows progress instead of a failure, and is recovered if the app quits before its turn.
        #expect(ProjectStatus.queued.isWorking)
    }

    @Test func theSidebarRingShowsTheWholeProject() {
        let link = Project(title: "t", sourceURL: "https://youtu.be/x", options: ProjectOptions()).pipelineStages
        let file = Project(title: "t", sourceURL: nil, options: ProjectOptions()).pipelineStages
        // 41% of the download is about a tenth of a link project.
        #expect(abs(LiveProgress(stage: .downloading, fraction: 0.41, detail: "").overall(stages: link) - 0.1025) < 1e-9)
        #expect(LiveProgress(stage: .transcribing, fraction: 0, detail: "").overall(stages: link) == 0.25)
        #expect(LiveProgress(stage: .framing, fraction: 1, detail: "").overall(stages: link) == 1)
        // A file has no download step, so transcribing is its first third.
        #expect(abs(LiveProgress(stage: .transcribing, fraction: 0.5, detail: "").overall(stages: file) - 1.0 / 6) < 1e-9)
        #expect(LiveProgress(stage: .queued, fraction: 0, detail: "").overall(stages: link) == 0)
    }

    @Test func onlyYouTubeLinksAreNamedEarly() async {
        // Other sites keep the host name until the download starts; no request is made for them.
        #expect(await Downloader.quickTitle(url: "https://vimeo.com/76979871") == nil)
        #expect(await Downloader.quickTitle(url: "https://notyoutube.com/watch?v=x") == nil)
        #expect(await Downloader.quickTitle(url: "not a link") == nil)
    }
}
