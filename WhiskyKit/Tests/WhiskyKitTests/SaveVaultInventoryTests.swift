//
//  SaveVaultInventoryTests.swift
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

final class SaveVaultInventoryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let vault: SaveVault
    }

    func testInventorySortsNewestFirstAndRetentionKeepsProtectedSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for number in 1 ... 5 {
            try Data("save-\(number)".utf8).write(to: fixture.source)
            _ = try fixture.vault.capture(
                bottleID: "test-bottle",
                gameID: "test-game",
                sources: [SaveSource(id: "progress", url: fixture.source, kind: .file)],
                createdAt: Date(timeIntervalSince1970: TimeInterval(number)),
                identifier: "snapshot-\(number)"
            )
        }

        let before = try fixture.vault.inventory(bottleID: "test-bottle", gameID: "test-game")
        XCTAssertEqual(before.verified.map(\.manifest.id), [
            "snapshot-5", "snapshot-4", "snapshot-3", "snapshot-2", "snapshot-1"
        ])
        let result = try fixture.vault.enforceRetention(
            bottleID: "test-bottle",
            gameID: "test-game",
            maximumSnapshots: 2,
            protectedSnapshotIDs: ["snapshot-1"]
        )

        XCTAssertEqual(result.keptSnapshotIDs, ["snapshot-5", "snapshot-4", "snapshot-1"])
        XCTAssertEqual(result.removedSnapshotIDs, ["snapshot-2", "snapshot-3"])
        let after = try fixture.vault.inventory(bottleID: "test-bottle", gameID: "test-game")
        XCTAssertEqual(after.verified.map(\.manifest.id), ["snapshot-5", "snapshot-4", "snapshot-1"])
    }

    func testCorruptSnapshotIsReportedAndBlocksRetentionDeletion() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for number in 1 ... 2 {
            try Data("save-\(number)".utf8).write(to: fixture.source)
            _ = try fixture.vault.capture(
                bottleID: "test-bottle",
                gameID: "test-game",
                sources: [SaveSource(id: "progress", url: fixture.source, kind: .file)],
                identifier: "snapshot-\(number)"
            )
        }
        let corruptURL = try fixture.vault.snapshotURL(
            bottleID: "test-bottle",
            gameID: "test-game",
            snapshotID: "snapshot-1"
        )
        try Data("tampered".utf8).write(to: corruptURL.appending(path: "payload/progress/file"))

        let inventory = try fixture.vault.inventory(bottleID: "test-bottle", gameID: "test-game")
        XCTAssertEqual(inventory.verified.map(\.manifest.id), ["snapshot-2"])
        XCTAssertEqual(inventory.invalidSnapshotIDs, ["snapshot-1"])
        XCTAssertThrowsError(try fixture.vault.enforceRetention(
            bottleID: "test-bottle",
            gameID: "test-game",
            maximumSnapshots: 1
        )) { error in
            XCTAssertEqual(
                error as? SaveVaultManagementError,
                .invalidSnapshotsPresent(["snapshot-1"])
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testRetentionRejectsZeroWithoutTouchingVault() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try fixture.vault.enforceRetention(
            bottleID: "test-bottle",
            gameID: "test-game",
            maximumSnapshots: 0
        )) { error in
            XCTAssertEqual(error as? SaveVaultManagementError, .invalidRetentionLimit(0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vault.rootURL.path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SaveVaultInventoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            source: root.appending(path: "save.dat"),
            vault: SaveVault(rootURL: root.appending(path: "vault"))
        )
    }
}
