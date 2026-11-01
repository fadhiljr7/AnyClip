<div align="center">

<img src="AnyClip/Assets.xcassets/AppIcon.appiconset/Icon-iOS-Dark-256@1x.png" width="128" height="128" alt="AnyClip app icon">

# AnyClip

**Turn long videos into short vertical clips, right on your Mac.**

Free. No account. No license key. No watermark of ours.

![macOS 27+](https://img.shields.io/badge/macOS-27%2B-000000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)

<img src="docs/images/editor.jpg" width="860" alt="The AnyClip editor showing a vertical clip with a hook title and captions, next to the Hook inspector">

</div>

## What it does

Paste a link or drop in a video. AnyClip transcribes it, finds the moments that work on their own, and frames each one for TikTok, Reels and Shorts, with captions and a hook title ready to edit. It is a native SwiftUI app with no Electron and no server of its own.

## Features

<table>
<tr>
<td width="50%" valign="top">

**🎬 Find the moments**
- Picks self-contained moments with a virality score
- Writes a title, an on-screen hook and a post caption in the video's language
- Ends clips on finished sentences, cut where the voice actually stops

</td>
<td width="50%" valign="top">

**📝 Transcribe your way**
- Apple speech recognition, built in
- YouTube's own transcript, the fastest for YouTube links
- Your SRT or VTT file
- WhisperKit, running offline on this Mac

</td>
</tr>
<tr>
<td valign="top">

**🖼️ Frame every speaker**
- Face tracking keeps the speaker in the crop
- Two-speaker stacked layout for podcasts and interviews
- Manual crop keyframes
- 9:16, 1:1, 4:5 and 16:9

</td>
<td valign="top">

**✨ Make it stop the scroll**
- 6 animated caption styles with word highlighting
- 4 hook title looks
- Cold-open teasers taken from later in the clip
- Animated B-roll keyword cards
- Your own text or logo watermark

</td>
</tr>
<tr>
<td valign="top">

**✂️ Edit and export**
- Trim by word on a speech timeline
- Edit captions directly, with a live preview that matches the export
- H.264 or HEVC, from 720p up to 4K
- Every export comes with its thumbnail: the video's first frame, ready to upload
- Library with search, Hot and Saved clips

</td>
<td valign="top">

**🧠 Choose your AI**
- Apple Intelligence, on this Mac, by default
- Your own key for Gemini, Groq, OpenAI, OpenRouter or Anthropic
- Any OpenAI-compatible server, including local ones
- Built-in scoring when no AI is available

</td>
</tr>
</table>

<div align="center">
<img src="docs/images/broll.jpg" width="49%" alt="A full-screen animated B-roll card in the preview">
<img src="docs/images/new-project.jpg" width="49%" alt="The New Project screen with video, transcript and clip options">
</div>

The interface is available in English and Bahasa Indonesia, and follows your system language.

## Getting started

There are no signed releases yet, so AnyClip is built from source for now.

**You need**
- macOS 27 or later
- Xcode 27 or later
- Apple Intelligence is optional. Without it, AnyClip uses built-in scoring.

**Build and run**

```bash
git clone https://github.com/fadhiljr7/AnyClip.git
cd AnyClip
open AnyClip.xcodeproj
```

1. Select the **AnyClip** target, open **Signing & Capabilities**, and choose your own team. You may also need your own bundle identifier.
2. Press **⌘R**. Xcode fetches [WhisperKit](https://github.com/argmaxinc/WhisperKit) by itself.

**Helper tools.** `yt-dlp` and Deno are only used for video links. AnyClip downloads them from their official GitHub releases when first needed and checks them against their published checksums. Files on your Mac don't need them. `ffmpeg` is optional and converts unusual formats: `brew install ffmpeg`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘N` | New project |
| `⌘O` | Import a video |
| `⌘E` / `⇧⌘E` | Export the clip / all clips |
| `⌘D` | Add to or remove from Saved |
| `⇧⌘R` | Show the export in Finder |
| `Space` | Play or pause, in the editor |
| `←` / `→` | Move one second, in the editor |
| `I` / `O` | Set the clip's start / end at the playhead |
| `⌥` while dragging a trim handle | Turn off word snapping |

## Privacy

Your videos, transcripts and clips stay on your Mac. There is no AnyClip account, server or analytics.

| Data | Where it goes |
|---|---|
| Videos, transcripts, library | Only on your Mac, in `~/Library/Application Support/AnyClip` |
| Transcripts sent for AI | Only to the provider you chose. With Apple Intelligence, they normally stay on this Mac. |
| API keys | Your macOS Keychain, and only ever sent to that provider |
| Browser cookies | Off by default. If you turn them on, yt-dlp uses them on this Mac for sign-in to the video site. |

## How it's built

```
AnyClip/
├── Models/    Project and clip data, teasers, B-roll plans, two-speaker layout rules
├── Engine/    Pipeline and export queue (Studio), rendering, AI providers,
│              transcription, face tracking, downloads
└── Views/     SwiftUI screens, the clip editor and onboarding
AnyClipTests/  Swift Testing suite, hosted by the app with a throwaway library
Scripts/       Release script: archive, notarize and package a DMG
```

Native Apple frameworks do the work: **AVFoundation** and **Core Animation** for rendering, so preview and export share one implementation, **Speech** for transcription, **Vision** for faces, **FoundationModels** for on-device AI, and **SwiftData** for the library.

## Contributing

Issues and pull requests are welcome. Before opening a pull request:

```bash
xcodebuild test -scheme AnyClip -destination 'platform=macOS'
```

- Add tests for behavior changes. The test suite uses an in-memory library, so it never touches your own.
- Every new interface string needs an Indonesian translation in `AnyClip/Localizable.xcstrings`.
- Follow Apple's Human Interface Guidelines, and keep the code free of compiler warnings.
- Never commit API keys or signing files.

## Responsible use

AnyClip is a tool for your own videos and for content you have the right to use. You are responsible for respecting copyright and each site's terms of service. AnyClip is not affiliated with YouTube, TikTok, Instagram or any other platform or AI provider it works with.

## License

AnyClip is free software under the [GNU General Public License v3.0](LICENSE).

## Thanks to

[yt-dlp](https://github.com/yt-dlp/yt-dlp) · [Deno](https://github.com/denoland/deno) · [WhisperKit](https://github.com/argmaxinc/WhisperKit) · [FFmpeg](https://ffmpeg.org)
