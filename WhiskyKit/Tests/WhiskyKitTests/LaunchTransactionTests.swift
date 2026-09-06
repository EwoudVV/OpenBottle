//
//  LaunchTransactionTests.swift
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

final class LaunchTransactionTests: XCTestCase {
    func testBottleIdentityIsDeterministicOpaqueAndPathSensitive() {
        let bottle = URL(fileURLWithPath: "/Users/player/Games/Private Bottle")
        let equivalent = URL(fileURLWithPath: "/Users/player/Games/folder/../Private Bottle")
        let other = URL(fileURLWithPath: "/Users/player/Games/Other Bottle")
        let identifier = BottleLaunchIdentity.id(for: bottle)

        XCTAssertEqual(identifier, BottleLaunchIdentity.id(for: equivalent))
        XCTAssertFalse(identifier == BottleLaunchIdentity.id(for: other))
        XCTAssertTrue(identifier.hasPrefix("bottle-"))
        XCTAssertEqual(identifier.count, 71)
        XCTAssertFalse(identifier.contains("player"))
        XCTAssertFalse(identifier.contains("Private"))
    }

    func testCompleteLifecycleIsDurableAndLeavesNoRecoveryWork() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        let identifier = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let created = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            identifier: identifier,
            at: started
        )
        XCTAssertEqual(created.stage, .created)
        XCTAssertEqual(created.bottleID, "test-bottle")

        _ = try await journal.advance(identifier, to: .preflightPassed, at: started.addingTimeInterval(1))
        let captured = try await journal.advance(
            identifier,
            to: .saveCaptured,
            saveSnapshotID: "snapshot-1",
            at: started.addingTimeInterval(2)
        )
        XCTAssertEqual(captured.saveSnapshotID, "snapshot-1")
        _ = try await journal.advance(identifier, to: .prepared, at: started.addingTimeInterval(3))
        _ = try await journal.advance(identifier, to: .launchRequested, at: started.addingTimeInterval(4))
        _ = try await journal.advance(identifier, to: .monitoring, at: started.addingTimeInterval(5))
        _ = try await journal.advance(identifier, to: .cleaningUp, at: started.addingTimeInterval(6))
        let completed = try await journal.advance(
            identifier,
            to: .completed,
            at: started.addingTimeInterval(7)
        )

        XCTAssertEqual(completed.stage, .completed)
        XCTAssertEqual(completed.saveSnapshotID, "snapshot-1")
        let persisted = try await journal.record(for: identifier)
        let history = try await journal.records()
        let unfinished = try await journal.unfinished()
        XCTAssertEqual(persisted, completed)
        XCTAssertEqual(history, [completed])
        XCTAssertTrue(unfinished.isEmpty)

        let recordURL = fixture
            .appending(path: identifier.uuidString.lowercased())
            .appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testInterruptedLaunchAppearsInRecoveryOrder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        let laterID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let earlierID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

        _ = try await journal.begin(
            bottleID: "later-bottle",
            gameID: "later-game",
            identifier: laterID,
            at: Date(timeIntervalSince1970: 200)
        )
        _ = try await journal.begin(
            bottleID: "earlier-bottle",
            gameID: "earlier-game",
            identifier: earlierID,
            at: Date(timeIntervalSince1970: 100)
        )
        _ = try await journal.advance(earlierID, to: .preflightPassed)

        let unfinished = try await journal.unfinished()
        XCTAssertEqual(unfinished.map(\.id), [earlierID, laterID])
        XCTAssertEqual(unfinished.map(\.stage), [.preflightPassed, .created])
    }

    func testInvalidTransitionDoesNotChangePersistedStage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        let identifier = UUID()
        _ = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            identifier: identifier
        )

        do {
            _ = try await journal.advance(identifier, to: .launchRequested)
            XCTFail("Expected invalid transition")
        } catch {
            XCTAssertEqual(
                error as? LaunchTransactionError,
                .invalidTransition(from: .created, nextStage: .launchRequested)
            )
        }
        let persisted = try await journal.record(for: identifier)
        XCTAssertEqual(persisted.stage, .created)
    }

    func testSaveCapturedRequiresSnapshotID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        let identifier = UUID()
        _ = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            identifier: identifier
        )
        _ = try await journal.advance(identifier, to: .preflightPassed)

        do {
            _ = try await journal.advance(identifier, to: .saveCaptured)
            XCTFail("Expected save snapshot requirement")
        } catch {
            XCTAssertEqual(error as? LaunchTransactionError, .saveSnapshotRequired)
        }
        let persisted = try await journal.record(for: identifier)
        XCTAssertEqual(persisted.stage, .preflightPassed)
    }

    func testFailureIsTerminalAndCarriesOnlyReasonCode() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        let identifier = UUID()
        _ = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            identifier: identifier
        )
        _ = try await journal.advance(identifier, to: .preflightPassed)
        let failed = try await journal.fail(identifier, code: "save-capture-failed")

        XCTAssertEqual(failed.stage, .failed)
        XCTAssertEqual(failed.failureCode, "save-capture-failed")
        let unfinished = try await journal.unfinished()
        XCTAssertTrue(unfinished.isEmpty)

        do {
            _ = try await journal.advance(identifier, to: .cleaningUp)
            XCTFail("Expected terminal transition failure")
        } catch {
            XCTAssertEqual(
                error as? LaunchTransactionError,
                .invalidTransition(from: .failed, nextStage: .cleaningUp)
            )
        }
    }

    func testFailureAfterPreparationRemainsRecoverableUntilCleanup() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        let identifier = UUID()
        _ = try await journal.begin(
            bottleID: "test-bottle",
            gameID: "test-game",
            identifier: identifier
        )
        _ = try await journal.advance(identifier, to: .preflightPassed)
        _ = try await journal.advance(identifier, to: .prepared)

        let recovery = try await journal.fail(identifier, code: "renderer-prepare-failed")
        XCTAssertEqual(recovery.stage, .recoveryNeeded)
        XCTAssertEqual(recovery.failureCode, "renderer-prepare-failed")
        let recovering = try await journal.unfinished()
        XCTAssertEqual(recovering.map(\.id), [identifier])

        _ = try await journal.advance(identifier, to: .cleaningUp)
        let failed = try await journal.advance(identifier, to: .failed)
        XCTAssertEqual(failed.failureCode, "renderer-prepare-failed")
        let unfinished = try await journal.unfinished()
        XCTAssertTrue(unfinished.isEmpty)
    }

    func testInvalidBottleOrGameIdentifierWritesNothing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let journal = LaunchTransactionJournal(rootURL: fixture)
        do {
            _ = try await journal.begin(
                bottleID: "../outside",
                gameID: "test-game"
            )
            XCTFail("Expected invalid identifier")
        } catch {
            XCTAssertEqual(
                error as? LaunchTransactionError,
                .invalidIdentifier("../outside")
            )
        }
        do {
            _ = try await journal.begin(
                bottleID: "test-bottle",
                gameID: "../../outside"
            )
            XCTFail("Expected invalid identifier")
        } catch {
            XCTAssertEqual(
                error as? LaunchTransactionError,
                .invalidIdentifier("../../outside")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
    }

    private func makeFixture() throws -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "LaunchTransactionTests-\(UUID().uuidString)")
    }
}
