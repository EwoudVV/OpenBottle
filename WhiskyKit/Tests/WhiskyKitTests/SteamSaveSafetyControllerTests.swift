//
//  SteamSaveSafetyControllerTests.swift
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

final class SteamSaveSafetyControllerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let bottleURL: URL
        let game: SteamGame
        let vault: SaveVault
        let restoreJournal: SaveRestoreJournal
    }

    func testDefaultGamePlanListsAndRestoresLaunchSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = fixture.game.installURL.appending(path: "saveables.dat")
        try Data("old-progress".utf8).write(to: progress)
        let launchJournal = LaunchTransactionJournal(rootURL: fixture.root.appending(path: "launch-journal"))
        let launchSafety = SteamLaunchSafetyController(
            vault: fixture.vault,
            journal: launchJournal
        )
        let preparation = try await launchSafety.prepare(
            game: fixture.game,
            bottleURL: fixture.bottleURL,
            identifier: UUID(),
            at: Date(timeIntervalSince1970: 100)
        )
        try Data("new-progress".utf8).write(to: progress)
        let saveSafety = SteamSaveSafetyController(vault: fixture.vault, restoreJournal: fixture.restoreJournal)

        let inventory = try await saveSafety.inventory(
            game: fixture.game,
            bottleURL: fixture.bottleURL
        )
        let snapshot = try XCTUnwrap(inventory.verified.first)
        let result = try await saveSafety.restore(
            snapshot: snapshot,
            game: fixture.game,
            bottleURL: fixture.bottleURL
        )

        XCTAssertEqual(preparation.saveSnapshot?.manifest.id, snapshot.manifest.id)
        XCTAssertEqual(try Data(contentsOf: progress), Data("old-progress".utf8))
        XCTAssertEqual(
            try Data(contentsOf: result.rollbackSnapshot.url.appending(path: "payload/progress/file")),
            Data("new-progress".utf8)
        )
        XCTAssertEqual(result.record.stage, .completed)
    }

    func testRecoveryWaitsForRunningGameThenRestoresOriginalState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try SteamGameSavePlanner.resolve(
            game: fixture.game,
            bottleURL: fixture.bottleURL,
            entries: GameDBLoader.loadDefaults(),
            wineUserName: "player"
        )
        let progress = fixture.game.installURL.appending(path: "saveables.dat")
        try Data("selected-old".utf8).write(to: progress)
        let target = try fixture.vault.capture(
            bottleID: BottleLaunchIdentity.id(for: fixture.bottleURL),
            gameID: plan.gameID,
            sources: plan.sources,
            identifier: "selected-save"
        )
        try Data("original-new".utf8).write(to: progress)
        let rollback = try fixture.vault.capture(
            bottleID: BottleLaunchIdentity.id(for: fixture.bottleURL),
            gameID: plan.gameID,
            sources: plan.sources,
            identifier: "rollback-save"
        )
        try Data("partial-old".utf8).write(to: progress)
        let operationID = UUID()
        let applying = try await applyingRecord(
            fixture,
            targetSnapshotID: target.manifest.id,
            rollbackSnapshotID: rollback.manifest.id,
            operationID: operationID
        )
        let saveSafety = SteamSaveSafetyController(vault: fixture.vault, restoreJournal: fixture.restoreJournal)

        let deferred = try await saveSafety.recoverUnfinished(
            bottleURL: fixture.bottleURL,
            games: [fixture.game],
            runningAppIDs: [fixture.game.appId]
        )
        XCTAssertTrue(deferred.isEmpty)
        XCTAssertEqual(try Data(contentsOf: progress), Data("partial-old".utf8))
        let stillApplying = try await fixture.restoreJournal.record(for: operationID)
        XCTAssertEqual(stillApplying, applying)

        let recovered = try await saveSafety.recoverUnfinished(
            bottleURL: fixture.bottleURL,
            games: [fixture.game],
            runningAppIDs: []
        )
        XCTAssertEqual(recovered.first?.stage, .failed)
        XCTAssertEqual(try Data(contentsOf: progress), Data("original-new".utf8))
    }

    func testLaunchSnapshotsRespectConfiguredRetentionLimit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = fixture.game.installURL.appending(path: "saveables.dat")
        let controller = SteamLaunchSafetyController(
            vault: fixture.vault,
            journal: LaunchTransactionJournal(rootURL: fixture.root.appending(path: "launch-journal")),
            maximumSnapshots: 2
        )
        for number in 1 ... 3 {
            try Data("progress-\(number)".utf8).write(to: progress)
            let preparation = try await controller.prepare(
                game: fixture.game,
                bottleURL: fixture.bottleURL,
                identifier: UUID(),
                at: Date(timeIntervalSince1970: TimeInterval(number))
            )
            _ = try await controller.markPrepared(preparation)
            _ = try await controller.markLaunchRequested(preparation)
            _ = try await controller.markMonitoring(preparation)
            _ = try await controller.complete(preparation)
        }

        let inventory = try fixture.vault.inventory(
            bottleID: BottleLaunchIdentity.id(for: fixture.bottleURL),
            gameID: "screw-drivers"
        )
        XCTAssertEqual(inventory.verified.count, 2)
        XCTAssertEqual(inventory.verified.map(\.manifest.createdAt), [
            Date(timeIntervalSince1970: 3),
            Date(timeIntervalSince1970: 2)
        ])
    }

    private func applyingRecord(
        _ fixture: Fixture,
        targetSnapshotID: String,
        rollbackSnapshotID: String,
        operationID: UUID
    ) async throws -> SaveRestoreRecord {
        _ = try await fixture.restoreJournal.begin(
            bottleID: BottleLaunchIdentity.id(for: fixture.bottleURL),
            gameID: "screw-drivers",
            targetSnapshotID: targetSnapshotID,
            identifier: operationID
        )
        _ = try await fixture.restoreJournal.advance(
            operationID,
            to: .rollbackCaptured,
            rollbackSnapshotID: rollbackSnapshotID
        )
        _ = try await fixture.restoreJournal.advance(operationID, to: .prepared)
        return try await fixture.restoreJournal.advance(operationID, to: .applying)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SteamSaveSafetyControllerTests-\(UUID().uuidString)")
        let bottleURL = root.appending(path: "bottle")
        let steamRoot = bottleURL.appending(path: "drive_c/Program Files (x86)/Steam")
        let steamApps = steamRoot.appending(path: "steamapps")
        let install = steamApps.appending(path: "common/Screw Drivers")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "drive_c/users/player"),
            withIntermediateDirectories: true
        )
        try Data().write(to: steamRoot.appending(path: "steam.exe"))
        try Data().write(to: install.appending(path: "Screw Drivers.exe"))
        let manifest = """
        "AppState"
        {
            "appid"        "1279510"
            "name"        "Screw Drivers"
            "installdir"        "Screw Drivers"
            "StateFlags"        "4"
        }
        """
        try manifest.write(
            to: steamApps.appending(path: "appmanifest_1279510.acf"),
            atomically: true,
            encoding: .utf8
        )
        let game = try XCTUnwrap(SteamLibrary.enumerate(bottleURL: bottleURL).first)
        let vault = SaveVault(rootURL: root.appending(path: "vault"))
        return Fixture(
            root: root,
            bottleURL: bottleURL,
            game: game,
            vault: vault,
            restoreJournal: SaveRestoreJournal(rootURL: root.appending(path: "restore-journal"))
        )
    }
}
