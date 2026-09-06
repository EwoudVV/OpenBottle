//
//  SteamLaunchSafetyControllerTests.swift
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

final class SteamLaunchSafetyControllerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let bottleURL: URL
        let game: SteamGame
    }

    func testKnownGameCapturesBeforeLaunchAndCompletesTheJournal() async throws {
        let fixture = try makeFixture(appID: 1_279_510)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("local-progress".utf8).write(
            to: fixture.game.installURL.appending(path: "saveables.dat")
        )
        let vault = SaveVault(rootURL: fixture.root.appending(path: "vault"))
        let journal = LaunchTransactionJournal(rootURL: fixture.root.appending(path: "journal"))
        let controller = SteamLaunchSafetyController(vault: vault, journal: journal)
        let identifier = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let preparation = try await controller.prepare(
            game: fixture.game,
            bottleURL: fixture.bottleURL,
            identifier: identifier,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let snapshot = try XCTUnwrap(preparation.saveSnapshot)
        let bottleID = BottleLaunchIdentity.id(for: fixture.bottleURL)
        XCTAssertEqual(snapshot.manifest.bottleID, bottleID)
        XCTAssertEqual(snapshot.manifest.gameID, "screw-drivers")
        XCTAssertEqual(snapshot.manifest.sources.count, 15)
        XCTAssertEqual(
            snapshot.manifest.sources.first { $0.id == "progress" }?.wasPresent,
            true
        )
        XCTAssertNoThrow(try vault.verify(snapshotAt: snapshot.url))
        let capturedRecord = try await journal.record(for: identifier)
        XCTAssertEqual(capturedRecord.stage, .saveCaptured)

        _ = try await controller.markPrepared(preparation)
        _ = try await controller.markLaunchRequested(preparation)
        _ = try await controller.markMonitoring(preparation)
        let completed = try await controller.complete(preparation)

        XCTAssertEqual(completed.stage, .completed)
        let unfinishedAfterCompletion = try await journal.unfinished()
        XCTAssertTrue(unfinishedAfterCompletion.isEmpty)
    }

    func testUnknownGameStartsAValidTransactionWithoutInventingSavePaths() async throws {
        let fixture = try makeFixture(appID: 999_999)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = LaunchTransactionJournal(rootURL: fixture.root.appending(path: "journal"))
        let controller = SteamLaunchSafetyController(
            vault: SaveVault(rootURL: fixture.root.appending(path: "vault")),
            journal: journal
        )
        let identifier = UUID()

        let preparation = try await controller.prepare(
            game: fixture.game,
            bottleURL: fixture.bottleURL,
            identifier: identifier
        )

        XCTAssertNil(preparation.saveSnapshot)
        let record = try await journal.record(for: identifier)
        XCTAssertEqual(record.bottleID, BottleLaunchIdentity.id(for: fixture.bottleURL))
        XCTAssertEqual(record.gameID, "steam-999999")
        XCTAssertEqual(record.stage, .preflightPassed)
    }

    func testRequiredMissingSaveFailsBeforePreparation() async throws {
        let fixture = try makeFixture(appID: 42)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = GameDBEntry(
            id: "required-save-game",
            title: "Required Save Game",
            steamAppId: 42,
            rating: .unverified,
            saveLocations: [
                GameSaveLocation(
                    id: "progress",
                    root: .gameInstall,
                    path: "missing.dat",
                    kind: .file,
                    required: true
                )
            ],
            variants: []
        )
        let journal = LaunchTransactionJournal(rootURL: fixture.root.appending(path: "journal"))
        let controller = SteamLaunchSafetyController(
            vault: SaveVault(rootURL: fixture.root.appending(path: "vault")),
            journal: journal,
            entries: [entry]
        )
        let identifier = UUID()

        do {
            _ = try await controller.prepare(
                game: fixture.game,
                bottleURL: fixture.bottleURL,
                identifier: identifier
            )
            XCTFail("Expected required save capture to fail")
        } catch {
            XCTAssertEqual(error as? SaveVaultError, .requiredSourceMissing("progress"))
        }

        let failed = try await journal.record(for: identifier)
        XCTAssertEqual(failed.stage, .failed)
        XCTAssertEqual(failed.failureCode, "save-capture-failed")
        let unfinishedAfterFailure = try await journal.unfinished()
        XCTAssertTrue(unfinishedAfterFailure.isEmpty)
    }

    private func makeFixture(appID: Int) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SteamLaunchSafetyControllerTests-\(UUID().uuidString)")
        let steamRoot = root.appending(path: "bottle/drive_c/Program Files (x86)/Steam")
        let steamApps = steamRoot.appending(path: "steamapps")
        let install = steamApps.appending(path: "common/Test Game")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try Data().write(to: steamRoot.appending(path: "steam.exe"))
        try Data().write(to: install.appending(path: "game.exe"))
        let manifest = """
        "AppState"
        {
            "appid"        "\(appID)"
            "name"        "Test Game"
            "installdir"        "Test Game"
            "StateFlags"        "4"
        }
        """
        try manifest.write(
            to: steamApps.appending(path: "appmanifest_\(appID).acf"),
            atomically: true,
            encoding: .utf8
        )
        let bottleURL = root.appending(path: "bottle")
        let game = try XCTUnwrap(SteamLibrary.enumerate(bottleURL: bottleURL).first)
        return Fixture(root: root, bottleURL: bottleURL, game: game)
    }
}
