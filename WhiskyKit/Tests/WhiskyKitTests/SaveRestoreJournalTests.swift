//
//  SaveRestoreJournalTests.swift
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

final class SaveRestoreJournalTests: XCTestCase {
    func testLifecyclePersistsRollbackAndCompletes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SaveRestoreJournal(rootURL: root)
        let identifier = UUID()
        let created = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            targetSnapshotID: "target-save",
            identifier: identifier,
            at: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(created.stage, .created)
        let captured = try await journal.advance(
            identifier,
            to: .rollbackCaptured,
            rollbackSnapshotID: "rollback-save"
        )
        XCTAssertEqual(captured.rollbackSnapshotID, "rollback-save")
        _ = try await journal.advance(identifier, to: .prepared)
        _ = try await journal.advance(identifier, to: .applying)
        _ = try await journal.advance(identifier, to: .cleaningUp)
        let completed = try await journal.advance(identifier, to: .completed)

        XCTAssertEqual(completed.stage, .completed)
        let persisted = try await journal.record(for: identifier)
        XCTAssertEqual(persisted, completed)
        let unfinished = try await journal.unfinished()
        XCTAssertTrue(unfinished.isEmpty)
    }

    func testApplyingFailureStaysRecoverableUntilRollbackFinishes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SaveRestoreJournal(rootURL: root)
        let identifier = UUID()
        _ = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            targetSnapshotID: "target-save",
            identifier: identifier
        )
        _ = try await journal.advance(
            identifier,
            to: .rollbackCaptured,
            rollbackSnapshotID: "rollback-save"
        )
        _ = try await journal.advance(identifier, to: .prepared)
        _ = try await journal.advance(identifier, to: .applying)

        let recovery = try await journal.fail(identifier, code: "restore-failed")
        XCTAssertEqual(recovery.stage, .recoveryNeeded)
        let unfinished = try await journal.unfinished()
        XCTAssertEqual(unfinished.map(\.id), [identifier])
        let failed = try await journal.finishRecovery(identifier)
        XCTAssertEqual(failed.stage, .failed)
        XCTAssertEqual(failed.failureCode, "restore-failed")
    }

    func testRollbackIDIsRequiredAndCannotChangeLater() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SaveRestoreJournal(rootURL: root)
        let identifier = UUID()
        _ = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            targetSnapshotID: "target-save",
            identifier: identifier
        )

        do {
            _ = try await journal.advance(identifier, to: .rollbackCaptured)
            XCTFail("Expected rollback snapshot requirement")
        } catch {
            XCTAssertEqual(error as? SaveRestoreJournalError, .rollbackSnapshotRequired)
        }
        _ = try await journal.advance(
            identifier,
            to: .rollbackCaptured,
            rollbackSnapshotID: "rollback-save"
        )
        do {
            _ = try await journal.advance(
                identifier,
                to: .prepared,
                rollbackSnapshotID: "different-save"
            )
            XCTFail("Expected rollback identity to stay fixed")
        } catch {
            XCTAssertEqual(
                error as? SaveRestoreJournalError,
                .invalidTransition(from: .rollbackCaptured, nextStage: .prepared)
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SaveRestoreJournalTests-\(UUID().uuidString)")
    }
}
