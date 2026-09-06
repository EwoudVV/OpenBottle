//
//  SaveVaultTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

@testable import WhiskyKit
import XCTest

final class SaveVaultTests: XCTestCase {
    func testSameGameAndSnapshotIDStayIsolatedByBottle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let firstSource = fixture.appending(path: "first.dat")
        let secondSource = fixture.appending(path: "second.dat")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))

        let first = try vault.capture(
            bottleID: "bottle-one",
            gameID: "test-game",
            sources: [SaveSource(id: "progress", url: firstSource, kind: .file)],
            identifier: "snapshot-1"
        )
        let second = try vault.capture(
            bottleID: "bottle-two",
            gameID: "test-game",
            sources: [SaveSource(id: "progress", url: secondSource, kind: .file)],
            identifier: "snapshot-1"
        )

        XCTAssertFalse(first.url == second.url)
        XCTAssertEqual(first.manifest.bottleID, "bottle-one")
        XCTAssertEqual(second.manifest.bottleID, "bottle-two")
        XCTAssertNoThrow(try vault.verify(snapshotAt: first.url))
        XCTAssertNoThrow(try vault.verify(snapshotAt: second.url))
    }

    func testCapturePublishesVerifiedPortableSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let singleFile = fixture.appending(path: "profile.dat")
        let saveDirectory = fixture.appending(path: "save-tree")
        try Data("profile".utf8).write(to: singleFile)
        try FileManager.default.createDirectory(
            at: saveDirectory.appending(path: "nested/empty"),
            withIntermediateDirectories: true
        )
        try Data("progress".utf8).write(to: saveDirectory.appending(path: "nested/progress.dat"))
        try Data("hidden".utf8).write(to: saveDirectory.appending(path: ".local-state"))

        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [
                SaveSource(id: "tree", url: saveDirectory, kind: .directory, required: true),
                SaveSource(id: "profile", url: singleFile, kind: .file, required: true)
            ],
            createdAt: createdAt,
            identifier: "snapshot-1"
        )

        XCTAssertEqual(snapshot.url.lastPathComponent, "snapshot-1")
        XCTAssertEqual(snapshot.manifest.bottleID, "test-bottle")
        XCTAssertEqual(snapshot.manifest.createdAt, createdAt)
        XCTAssertEqual(snapshot.manifest.sources.map(\.id), ["profile", "tree"])
        XCTAssertEqual(snapshot.manifest.files.count, 3)
        XCTAssertEqual(
            snapshot.manifest.directories.map(\.relativePath),
            ["nested", "nested/empty"]
        )
        XCTAssertTrue(snapshot.manifest.sources.allSatisfy(\.wasPresent))
        XCTAssertEqual(try vault.verify(snapshotAt: snapshot.url), snapshot)

        let manifestData = try Data(
            contentsOf: snapshot.url.appending(path: SaveVault.manifestFileName)
        )
        let manifestText = try XCTUnwrap(String(data: manifestData, encoding: .utf8))
        XCTAssertFalse(manifestText.contains(fixture.path))
        XCTAssertEqual(try Data(contentsOf: singleFile), Data("profile".utf8))
        XCTAssertEqual(
            try Data(contentsOf: saveDirectory.appending(path: "nested/progress.dat")),
            Data("progress".utf8)
        )
    }

    func testOptionalMissingSourceIsRecordedWithoutPayload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))
        let snapshot = try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [
                SaveSource(
                    id: "future-save",
                    url: fixture.appending(path: "not-created-yet"),
                    kind: .directory
                )
            ],
            identifier: "snapshot-optional"
        )

        XCTAssertEqual(snapshot.manifest.sources.count, 1)
        XCTAssertEqual(snapshot.manifest.sources.first?.wasPresent, false)
        XCTAssertTrue(snapshot.manifest.files.isEmpty)
        XCTAssertNoThrow(try vault.verify(snapshotAt: snapshot.url))
    }

    func testRequiredMissingSourceLeavesNoPublishedOrStagingSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let vaultURL = fixture.appending(path: "vault")
        let vault = SaveVault(rootURL: vaultURL)
        XCTAssertThrowsError(try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [
                SaveSource(
                    id: "required",
                    url: fixture.appending(path: "missing"),
                    kind: .file,
                    required: true
                )
            ],
            identifier: "snapshot-required"
        )) { error in
            XCTAssertEqual(error as? SaveVaultError, .requiredSourceMissing("required"))
        }

        let gameURL = vaultURL.appending(path: "test-bottle/test-game")
        let children = try FileManager.default.contentsOfDirectory(
            at: gameURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(children.isEmpty)
    }

    func testSymlinkFailsClosedAndCleansStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appending(path: "source")
        let outside = fixture.appending(path: "outside.dat")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "linked.dat"),
            withDestinationURL: outside
        )

        let vaultURL = fixture.appending(path: "vault")
        let vault = SaveVault(rootURL: vaultURL)
        XCTAssertThrowsError(try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [SaveSource(id: "tree", url: source, kind: .directory, required: true)],
            identifier: "snapshot-link"
        )) { error in
            guard let vaultError = error as? SaveVaultError,
                  case .symbolicLinkNotAllowed = vaultError
            else {
                return XCTFail("Expected symbolicLinkNotAllowed, got \(error)")
            }
        }

        let gameURL = vaultURL.appending(path: "test-bottle/test-game")
        let children = try FileManager.default.contentsOfDirectory(
            at: gameURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(children.isEmpty)
    }

    func testVerificationRejectsTamperedPayload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appending(path: "save.dat")
        try Data("first".utf8).write(to: source)
        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))
        let snapshot = try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [SaveSource(id: "single", url: source, kind: .file, required: true)],
            identifier: "snapshot-tamper"
        )

        let payload = snapshot.url.appending(path: "payload/single/file")
        try Data("other".utf8).write(to: payload)

        XCTAssertThrowsError(try vault.verify(snapshotAt: snapshot.url)) { error in
            XCTAssertEqual(error as? SaveVaultError, .checksumMismatch("single/file"))
        }
    }

    func testVerificationRejectsUnlistedPayload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appending(path: "save.dat")
        try Data("save".utf8).write(to: source)
        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))
        let snapshot = try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [SaveSource(id: "single", url: source, kind: .file, required: true)],
            identifier: "snapshot-extra"
        )

        let extra = snapshot.url.appending(path: "payload/single/extra.dat")
        try Data("extra".utf8).write(to: extra)

        XCTAssertThrowsError(try vault.verify(snapshotAt: snapshot.url)) { error in
            XCTAssertEqual(error as? SaveVaultError, .unexpectedPayload("single/extra.dat"))
        }
    }

    func testVaultCannotLiveInsideCapturedDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = fixture.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let vault = SaveVault(rootURL: source.appending(path: "vault"))

        XCTAssertThrowsError(try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [SaveSource(id: "tree", url: source, kind: .directory)],
            identifier: "snapshot-overlap"
        )) { error in
            XCTAssertEqual(error as? SaveVaultError, .overlappingPaths("tree"))
        }
    }

    func testDuplicateSourceIDsAreRejectedBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = fixture.appending(path: "first.dat")
        let second = fixture.appending(path: "second.dat")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))

        XCTAssertThrowsError(try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [
                SaveSource(id: "same", url: first, kind: .file),
                SaveSource(id: "same", url: second, kind: .file)
            ],
            identifier: "snapshot-duplicate"
        )) { error in
            XCTAssertEqual(error as? SaveVaultError, .duplicateSourceID("same"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.rootURL.path))
    }

    func testNestedSourcesAreRejectedBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let parent = fixture.appending(path: "parent")
        let child = parent.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))

        XCTAssertThrowsError(try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [
                SaveSource(id: "parent", url: parent, kind: .directory),
                SaveSource(id: "child", url: child, kind: .directory)
            ],
            identifier: "snapshot-nested"
        )) { error in
            XCTAssertEqual(error as? SaveVaultError, .overlappingPaths("child"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.rootURL.path))
    }

    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SaveVaultTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
