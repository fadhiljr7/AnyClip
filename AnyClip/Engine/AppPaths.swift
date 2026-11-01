//
//  AppPaths.swift
//  AnyClip
//

import Foundation

nonisolated enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "AnyClip", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let projects: URL = {
        let url = support.appending(path: "Projects", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let tools: URL = {
        let url = support.appending(path: "bin", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var defaultExportFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appending(path: "AnyClip", directoryHint: .isDirectory)
    }

    static var exportFolder: URL {
        if let path = UserDefaults.standard.string(forKey: AppSettings.Key.exportFolder), !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return defaultExportFolder
    }

    /// Puts `file` at `destination` in one step, replacing what's there. A failure leaves the old file in place.
    static func replace(_ destination: URL, with file: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: file)
        } else {
            try fm.moveItem(at: file, to: destination)
        }
    }

    /// Where a clip's export goes. Exporting again replaces the clip's own file; a file that belongs to something
    /// else, such as another project with the same title, is never overwritten.
    static func exportFile(in folder: URL, index: Int, title: String, previous: URL?,
                           exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> URL {
        unusedFile(in: folder, stem: String(format: "%02d ", index + 1) + safeFileName(title), ext: "mp4", previous: previous, exists: exists)
    }

    /// Where a clip's exported cover image goes, e.g. "01 Thumbnail.jpg", under the same no-overwrite rule.
    static func thumbnailFile(in folder: URL, index: Int, previous: URL?,
                              exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> URL {
        unusedFile(in: folder, stem: String(format: "%02d Thumbnail", index + 1), ext: "jpg", previous: previous, exists: exists)
    }

    private static func unusedFile(in folder: URL, stem: String, ext: String, previous: URL?, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appending(path: "\(stem).\(ext)")
        var copy = 2
        while exists(candidate), candidate.standardizedFileURL != previous?.standardizedFileURL {
            candidate = folder.appending(path: "\(stem) \(copy).\(ext)")
            copy += 1
        }
        return candidate
    }

    static func safeFileName(_ s: String, maxLength: Int = 60) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Titles come from websites and AI models: leading dots would hide the file, or make ".." a way out of the folder.
        let visible = collapsed.drop { $0 == "." || $0 == " " }
        let trimmed = String(visible.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Clip" : trimmed
    }
}
