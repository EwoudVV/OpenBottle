//
//  LaunchSafetyControllerTests.swift
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

import Foundation
@testable import WhiskyKit
import XCTest

final class LaunchSafetyControllerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let bottle: URL
        let renderer: URL
        let save: URL
    }

    func testOneTransactionProtectsSaveAndRestoresConfiguration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launchJournal = LaunchTransactionJournal(rootURL: fixture.root.appending(path: "transactions"))
        let saveVault = SaveVault(rootURL: fixture.root.appending(path: "save-vault"))
        let controller = LaunchSafetyController(
            saveVault: saveVault,
            journal: launchJournal,
            configurationVault: SaveVault(rootURL: fixture.root.appending(path: "config-vault")),
            configurationRestoreJournal: SaveRestoreJournal(
                rootURL: fixture.root.appending(path: "config-restores")
            )
        )
        let identifier = UUID()

        let futureSave = fixture.bottle.appending(path: "future-save")
        let preparation = try await controller.begin(
            bottleURL: fixture.bottle,
            gameID: "standalone-game",
            saveSources: [
                SaveSource(id: "progress", url: fixture.save, kind: .file),
                SaveSource(id: "future", url: futureSave, kind: .directory)
            ],
            identifier: identifier
        )
        XCTAssertTrue(preparation.saveSnapshot != nil)
        _ = try await controller.prepareConfiguration(preparation)

        try Data("temporary-renderer".utf8).write(to: fixture.renderer)
        try Data("new-progress".utf8).write(to: fixture.save)
        try FileManager.default.createDirectory(at: futureSave, withIntermediateDirectories: true)
        try Data("first-run-save".utf8).write(to: futureSave.appending(path: "slot.dat"))
        _ = try await controller.markLaunchRequested(preparation)
        _ = try await controller.markMonitoring(preparation)
        let completed = try await controller.finish(preparation)

        XCTAssertEqual(completed.stage, .completed)
        let postLaunchID = try XCTUnwrap(completed.postLaunchSaveSnapshotID)
        let postLaunchURL = try saveVault.snapshotURL(
            bottleID: preparation.bottleID,
            gameID: preparation.gameID,
            snapshotID: postLaunchID
        )
        let postLaunch = try saveVault.verify(snapshotAt: postLaunchURL)
        XCTAssertEqual(
            postLaunch.manifest.sources.first { $0.id == "future" }?.wasPresent,
            true
        )
        XCTAssertEqual(try Data(contentsOf: fixture.renderer), Data("original-renderer".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.save), Data("new-progress".utf8))
        let unfinished = try await launchJournal.unfinished()
        XCTAssertTrue(unfinished.isEmpty)
    }

    func testBottleLeaseBlocksOverlapAndReleasesAfterCleanup() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = LaunchTransactionJournal(rootURL: fixture.root.appending(path: "transactions"))
        let controller = LaunchSafetyController(
            saveVault: SaveVault(rootURL: fixture.root.appending(path: "save-vault")),
            journal: journal
        )
        let first = try await controller.begin(
            bottleURL: fixture.bottle,
            gameID: "first-game",
            saveSources: []
        )

        do {
            _ = try await controller.begin(
                bottleURL: fixture.bottle,
                gameID: "second-game",
                saveSources: []
            )
            XCTFail("Expected overlapping launch to be blocked")
        } catch {
            XCTAssertEqual(error as? LaunchLeaseError, .bottleBusy)
        }

        let firstRecord = try await journal.record(for: first.transactionID)
        _ = try await controller.finishInterrupted(firstRecord, bottleURL: fixture.bottle)
        let second = try await controller.begin(
            bottleURL: fixture.bottle,
            gameID: "second-game",
            saveSources: []
        )
        let secondRecord = try await journal.record(for: second.transactionID)
        _ = try await controller.finishInterrupted(secondRecord, bottleURL: fixture.bottle)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchSafetyControllerTests-\(UUID().uuidString)")
        let bottle = root.appending(path: "bottle")
        let system32 = bottle.appending(path: "drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let renderer = system32.appending(path: "d3d11.dll")
        let save = bottle.appending(path: "save.dat")
        try Data("original-renderer".utf8).write(to: renderer)
        try Data("original-progress".utf8).write(to: save)
        return Fixture(root: root, bottle: bottle, renderer: renderer, save: save)
    }
}
