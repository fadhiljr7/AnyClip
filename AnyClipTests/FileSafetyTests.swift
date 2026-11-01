//
//  FileSafetyTests.swift
//  AnyClipTests
//
//  File names built from web titles, export destinations and the library file.
//

import Testing
import Foundation
import SQLite3
import SwiftData
@testable import AnyClip

struct FileSafetyTests {
    @Test func namesCantLeaveTheFolderOrHide() {
        #expect(AppPaths.safeFileName("..") == "Clip")
        #expect(AppPaths.safeFileName("../../etc/passwd") == "etc passwd")
        #expect(AppPaths.safeFileName(".hidden") == "hidden")
        #expect(AppPaths.safeFileName("  ... ") == "Clip")
        #expect(AppPaths.safeFileName("Why: money?") == "Why money")
        #expect(AppPaths.safeFileName("Bab 1. Awal") == "Bab 1. Awal")
    }

    private let folder = URL(filePath: "/tmp/AnyClip/Same Title")

    @Test func exportingAgainReplacesTheClipsOwnFile() {
        let own = folder.appending(path: "01 Money.mp4")
        let url = AppPaths.exportFile(in: folder, index: 0, title: "Money", previous: own, exists: { $0 == own })
        #expect(url == own)
    }

    @Test func anotherProjectsFileIsNeverOverwritten() {
        let taken: Set<String> = ["01 Money.mp4", "01 Money 2.mp4"]
        let url = AppPaths.exportFile(in: folder, index: 0, title: "Money", previous: nil, exists: { taken.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "01 Money 3.mp4")
    }

    @Test func aRenamedClipGetsANewFile() {
        let old = folder.appending(path: "01 Old.mp4")
        let url = AppPaths.exportFile(in: folder, index: 0, title: "New", previous: old, exists: { $0 == old })
        #expect(url.lastPathComponent == "01 New.mp4")
    }

    @Test func thumbnailsAreNamedAfterTheClipNumber() {
        let url = AppPaths.thumbnailFile(in: folder, index: 0, previous: nil, exists: { _ in false })
        #expect(url.lastPathComponent == "01 Thumbnail.jpg")
        #expect(AppPaths.thumbnailFile(in: folder, index: 11, previous: nil, exists: { _ in false }).lastPathComponent == "12 Thumbnail.jpg")
    }

    @Test func exportingAgainReplacesTheClipsOwnThumbnail() {
        let own = folder.appending(path: "01 Thumbnail.jpg")
        #expect(AppPaths.thumbnailFile(in: folder, index: 0, previous: own, exists: { $0 == own }) == own)
    }

    @Test func anotherProjectsThumbnailIsNeverOverwritten() {
        let own = folder.appending(path: "01 Thumbnail.jpg")
        #expect(AppPaths.thumbnailFile(in: folder, index: 0, previous: nil, exists: { $0 == own }).lastPathComponent == "01 Thumbnail 2.jpg")
    }

    @Test func replacingWorksWithAndWithoutAnExistingFile() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "a.txt")
        for text in ["first", "second"] {
            let new = dir.appending(path: "\(text).tmp")
            try Data(text.utf8).write(to: new)
            try AppPaths.replace(dest, with: new)
            #expect(try String(contentsOf: dest, encoding: .utf8) == text)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) == ["a.txt"])
    }

    // MARK: Library

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "anyclip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A database with these tables, in write-ahead mode like a running app's.
    private func makeDatabase(at url: URL, tables: [String]) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
        for table in tables {
            try #require(sqlite3_exec(db, "CREATE TABLE \(table)(ZTITLE TEXT); INSERT INTO \(table) VALUES('kept');", nil, nil, nil) == SQLITE_OK)
        }
    }

    private func rows(in url: URL, table: String) -> Int {
        var db: OpaquePointer?
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
            sqlite3_close(db)
        }
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(statement, 0))
    }

    @Test func theOldLibraryIsCopiedAndKept() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appending(path: "default.store"), new = dir.appending(path: "AnyClip.store")
        try makeDatabase(at: legacy, tables: ["ZPROJECT", "ZCLIP"])
        #expect(LibraryFiles.adoptLegacyStore(from: legacy, to: new))
        #expect(rows(in: new, table: "ZPROJECT") == 1)
        #expect(rows(in: legacy, table: "ZPROJECT") == 1)
    }

    @Test func anotherAppsDatabaseIsLeftAlone() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appending(path: "default.store"), new = dir.appending(path: "AnyClip.store")
        try makeDatabase(at: legacy, tables: ["ZNOTES"])
        #expect(!LibraryFiles.adoptLegacyStore(from: legacy, to: new))
        #expect(!FileManager.default.fileExists(atPath: new.path(percentEncoded: false)))
    }

    @Test func aLibraryAlreadyInPlaceIsNeverReplaced() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appending(path: "default.store"), new = dir.appending(path: "AnyClip.store")
        try makeDatabase(at: legacy, tables: ["ZPROJECT", "ZCLIP"])
        try Data("mine".utf8).write(to: new)
        #expect(!LibraryFiles.adoptLegacyStore(from: legacy, to: new))
        #expect(try String(contentsOf: new, encoding: .utf8) == "mine")
    }

    @Test func aDamagedLibraryIsSetAsideNotDeleted() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "AnyClip.store")
        try Data("damaged".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(filePath: store.path(percentEncoded: false) + "-wal"))
        #expect(!LibraryFiles.isAnyClipLibrary(store))
        let folder = try LibraryFiles.setAside(store)
        #expect(!FileManager.default.fileExists(atPath: store.path(percentEncoded: false)))
        #expect(try String(contentsOf: folder.appending(path: "AnyClip.store"), encoding: .utf8) == "damaged")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "AnyClip.store-wal").path(percentEncoded: false)))
    }

    @MainActor
    @Test func theTestSuiteUsesAThrowawayLibrary() {
        #expect(AppStore.isHostingTests)
        let inMemory = AppStore.container.configurations.allSatisfy { $0.isStoredInMemoryOnly }
        #expect(inMemory)
    }
}
