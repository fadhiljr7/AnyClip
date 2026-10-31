//
//  AppStore.swift
//  AnyClip
//
//  Opens the library database. It lives in AnyClip's own folder: outside the App
//  Sandbox, SwiftData's default `default.store` sits directly in Application
//  Support, where any other unsandboxed SwiftData app would open the same file.
//

import AppKit
import Foundation
import SQLite3
import SwiftData

@MainActor
enum AppStore {
    static let container = open()

    /// True in the app launched to host the test suite, which must never touch the real library.
    nonisolated static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var storeURL: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "libraryPath") { return URL(filePath: path) }
        #endif
        return AppPaths.support.appending(path: "AnyClip.store")
    }

    /// Where earlier builds kept the library. Left in place as a backup after it's copied.
    private static var legacyStoreURL: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "legacyLibraryPath") { return URL(filePath: path) }
        #endif
        return AppPaths.support.deletingLastPathComponent().appending(path: "default.store")
    }

    private static func open() -> ModelContainer {
        if isHostingTests {
            do {
                return try make(ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("Could not create the in-memory test store: \(error)")
            }
        }
        let url = storeURL
        LibraryFiles.adoptLegacyStore(from: legacyStoreURL, to: url)
        do {
            return try make(ModelConfiguration(url: url))
        } catch {
            return recover(from: error, url: url)
        }
    }

    private static func make(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: Project.self, Clip.self, configurations: configuration)
    }

    /// The library can't be opened, usually because the file is damaged. Nothing is deleted: the person chooses
    /// between quitting and setting the file aside to start over.
    private static func recover(from error: Error, url: URL) -> ModelContainer {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "AnyClip Can’t Open Your Library")
        alert.informativeText = String(localized: "The library file may be damaged. You can start with an empty library — the old file is kept in AnyClip’s folder so it isn’t lost — or quit and restore it from a backup.\n\n\(error.localizedDescription)")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Start with an Empty Library"))
        guard alert.runModal() == .alertSecondButtonReturn else { exit(1) }
        do {
            try LibraryFiles.setAside(url)
            return try make(ModelConfiguration(url: url))
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = String(localized: "AnyClip Can’t Open Your Library")
            failure.informativeText = error.localizedDescription
            failure.runModal()
            exit(1)
        }
    }

    /// Writes pending changes when the app quits; a failure is only worth a log line by then.
    static func saveOnQuit() {
        do {
            try container.mainContext.save()
        } catch {
            engineLog("couldn't save the library on quit: \(error)")
        }
    }
}

/// File operations on the library database, away from SwiftData so they can be tested on their own.
nonisolated enum LibraryFiles {
    private static let suffixes = ["", "-wal", "-shm"]

    /// Copies the library from its old location, once. The file only counts as AnyClip's if it has AnyClip's tables,
    /// since other apps can leave a `default.store` in the same place. A failed copy leaves nothing behind.
    @discardableResult
    static func adoptLegacyStore(from legacy: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path(percentEncoded: false)),
              fm.fileExists(atPath: legacy.path(percentEncoded: false)),
              isAnyClipLibrary(legacy) else { return false }
        if backup(legacy, to: destination) { return true }
        remove(destination)
        return false
    }

    /// Moves the database and its journal files into a dated folder beside it, and returns that folder.
    @discardableResult
    static func setAside(_ store: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let folder = store.deletingLastPathComponent().appending(path: "Damaged Library \(stamp)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in suffixes {
            let file = URL(filePath: store.path(percentEncoded: false) + suffix)
            guard fm.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            try fm.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
        }
        return folder
    }

    static func isAnyClipLibrary(_ url: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('ZPROJECT', 'ZCLIP')"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) == 2
    }

    /// A consistent single-file copy that includes whatever is still in the source's write-ahead log.
    private static func backup(_ source: URL, to destination: URL) -> Bool {
        var from: OpaquePointer?, to: OpaquePointer?
        defer {
            sqlite3_close(from)
            sqlite3_close(to)
        }
        guard sqlite3_open_v2(source.path(percentEncoded: false), &from, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path(percentEncoded: false), &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let copy = sqlite3_backup_init(to, "main", from, "main") else { return false }
        let status = sqlite3_backup_step(copy, -1)
        sqlite3_backup_finish(copy)
        return status == SQLITE_DONE
    }

    private static func remove(_ store: URL) {
        for suffix in suffixes {
            try? FileManager.default.removeItem(at: URL(filePath: store.path(percentEncoded: false) + suffix))
        }
    }
}
