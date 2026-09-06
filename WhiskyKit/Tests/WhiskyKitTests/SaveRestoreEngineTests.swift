//
//  SaveRestoreEngineTests.swift
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

final class SaveRestoreEngineTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let vault: SaveVault
        let journal: SaveRestoreJournal
        let engine: SaveRestoreEngine
        let sources: [SaveSource]
    }

    func testRestorePreservesCurrentStateAndExactlyAppliesSelectedSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldState(fixture)
        let target = try capture(fixture, identifier: "old-save", at: 100)
        try writeNewState(fixture)
        let operationID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let result = try await fixture.engine.restore(
            snapshotAt: target.url,
            sources: fixture.sources,
            identifier: operationID,
            at: Date(timeIntervalSince1970: 200)
        )

        try assertOldState(fixture)
        XCTAssertEqual(result.record.stage, .completed)
        XCTAssertEqual(result.restoredSnapshot.manifest.id, "old-save")
        XCTAssertEqual(
            try Data(contentsOf: result.rollbackSnapshot.url.appending(path: "payload/progress/file")),
            Data("new-progress".utf8)
        )
        XCTAssertEqual(
            result.rollbackSnapshot.manifest.sources.first { $0.id == "future" }?.wasPresent,
            true
        )
        let unfinishedAfterRestore = try await fixture.journal.unfinished()
        XCTAssertTrue(unfinishedAfterRestore.isEmpty)
        XCTAssertTrue(restoreArtifacts(in: fixture).isEmpty)
    }

    func testInterruptedApplyReinstatesTheRollbackSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldState(fixture)
        let target = try capture(fixture, identifier: "old-save", at: 100)
        try writeNewState(fixture)
        let rollback = try capture(fixture, identifier: "rollback-save", at: 200)
        let operationID = UUID()
        _ = try await fixture.journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            targetSnapshotID: target.manifest.id,
            identifier: operationID
        )
        _ = try await fixture.journal.advance(
            operationID,
            to: .rollbackCaptured,
            rollbackSnapshotID: rollback.manifest.id
        )
        _ = try await fixture.journal.advance(operationID, to: .prepared)
        let applying = try await fixture.journal.advance(operationID, to: .applying)
        try writeOldState(fixture)

        let recovered = try await fixture.engine.recover(applying, sources: fixture.sources)

        try assertNewState(fixture)
        XCTAssertEqual(recovered.stage, .failed)
        XCTAssertEqual(recovered.failureCode, "interrupted-restore")
        let unfinishedAfterRecovery = try await fixture.journal.unfinished()
        XCTAssertTrue(unfinishedAfterRecovery.isEmpty)
        XCTAssertTrue(restoreArtifacts(in: fixture).isEmpty)
    }

    func testInterruptedCleanupKeepsTheVerifiedRestoredState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldState(fixture)
        let target = try capture(fixture, identifier: "old-save", at: 100)
        try writeNewState(fixture)
        let rollback = try capture(fixture, identifier: "rollback-save", at: 200)
        try writeOldState(fixture)
        let operationID = UUID()
        _ = try await fixture.journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            targetSnapshotID: target.manifest.id,
            identifier: operationID
        )
        _ = try await fixture.journal.advance(
            operationID,
            to: .rollbackCaptured,
            rollbackSnapshotID: rollback.manifest.id
        )
        _ = try await fixture.journal.advance(operationID, to: .prepared)
        _ = try await fixture.journal.advance(operationID, to: .applying)
        let cleaning = try await fixture.journal.advance(operationID, to: .cleaningUp)
        let artifact = fixture.root.appending(
            path: "live/.openbottle-restore-\(operationID.uuidString.lowercased())-leftover"
        )
        try Data("old-copy".utf8).write(to: artifact)

        let completed = try await fixture.engine.recover(cleaning, sources: fixture.sources)

        try assertOldState(fixture)
        XCTAssertEqual(completed.stage, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    func testTamperedSnapshotFailsBeforeCreatingRestoreRecord() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldState(fixture)
        let target = try capture(fixture, identifier: "old-save", at: 100)
        try writeNewState(fixture)
        try Data("bad".utf8).write(to: target.url.appending(path: "payload/progress/file"))

        do {
            _ = try await fixture.engine.restore(snapshotAt: target.url, sources: fixture.sources)
            XCTFail("Expected tampered snapshot rejection")
        } catch {
            XCTAssertEqual(error as? SaveVaultError, .checksumMismatch("progress/file"))
        }

        try assertNewState(fixture)
        let unfinishedAfterRejection = try await fixture.journal.unfinished()
        XCTAssertTrue(unfinishedAfterRejection.isEmpty)
    }

    func testMismatchedSourcePlanFailsBeforeCreatingRollback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeOldState(fixture)
        let target = try capture(fixture, identifier: "old-save", at: 100)

        do {
            _ = try await fixture.engine.restore(
                snapshotAt: target.url,
                sources: Array(fixture.sources.dropLast())
            )
            XCTFail("Expected source plan mismatch")
        } catch {
            XCTAssertEqual(error as? SaveRestoreError, .sourcePlanMismatch("source-count"))
        }
        XCTAssertEqual(try fixture.vault.inventory(
            bottleID: "test-bottle",
            gameID: "test-game"
        ).verified.count, 1)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SaveRestoreEngineTests-\(UUID().uuidString)")
        let live = root.appending(path: "live")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let vault = SaveVault(rootURL: root.appending(path: "vault"))
        let journal = SaveRestoreJournal(rootURL: root.appending(path: "journal"))
        return Fixture(
            root: root,
            vault: vault,
            journal: journal,
            engine: SaveRestoreEngine(vault: vault, journal: journal),
            sources: [
                SaveSource(id: "progress", url: live.appending(path: "progress.dat"), kind: .file),
                SaveSource(id: "cars", url: live.appending(path: "cars"), kind: .directory),
                SaveSource(id: "future", url: live.appending(path: "future.dat"), kind: .file)
            ]
        )
    }

    private func capture(_ fixture: Fixture, identifier: String, at timestamp: TimeInterval) throws -> SaveSnapshot {
        try fixture.vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: fixture.sources,
            createdAt: Date(timeIntervalSince1970: timestamp),
            identifier: identifier
        )
    }

    private func writeOldState(_ fixture: Fixture) throws {
        try clearLiveState(fixture)
        let live = fixture.root.appending(path: "live")
        try FileManager.default.createDirectory(
            at: live.appending(path: "cars/empty"),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: live.appending(path: "progress.dat"))
        try Data("old-car".utf8).write(to: live.appending(path: "cars/old.car"))
    }

    private func writeNewState(_ fixture: Fixture) throws {
        try clearLiveState(fixture)
        let live = fixture.root.appending(path: "live")
        try FileManager.default.createDirectory(at: live.appending(path: "cars"), withIntermediateDirectories: true)
        try Data("new-progress".utf8).write(to: live.appending(path: "progress.dat"))
        try Data("new-car".utf8).write(to: live.appending(path: "cars/new.car"))
        try Data("future".utf8).write(to: live.appending(path: "future.dat"))
    }

    private func clearLiveState(_ fixture: Fixture) throws {
        for source in fixture.sources where FileManager.default.fileExists(atPath: source.url.path) {
            try FileManager.default.removeItem(at: source.url)
        }
    }

    private func assertOldState(_ fixture: Fixture) throws {
        let live = fixture.root.appending(path: "live")
        XCTAssertEqual(try Data(contentsOf: live.appending(path: "progress.dat")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: live.appending(path: "cars/old.car")), Data("old-car".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.appending(path: "cars/empty").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appending(path: "cars/new.car").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appending(path: "future.dat").path))
    }

    private func assertNewState(_ fixture: Fixture) throws {
        let live = fixture.root.appending(path: "live")
        XCTAssertEqual(
            try Data(contentsOf: live.appending(path: "progress.dat")),
            Data("new-progress".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: live.appending(path: "cars/new.car")), Data("new-car".utf8))
        XCTAssertEqual(try Data(contentsOf: live.appending(path: "future.dat")), Data("future".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appending(path: "cars/old.car").path))
    }

    private func restoreArtifacts(in fixture: Fixture) -> [URL] {
        let live = fixture.root.appending(path: "live")
        let contents = try? FileManager.default.contentsOfDirectory(
            at: live,
            includingPropertiesForKeys: nil
        )
        return contents?.filter { $0.lastPathComponent.hasPrefix(".openbottle-restore-") } ?? []
    }
}
