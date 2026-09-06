//
//  SteamLaunchSafetyIntegrationTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Steam launch safety integration")
@MainActor
struct SteamLaunchSafetyIntegrationTests {
    @Test("A verified save snapshot is published before Steam gets the launch request")
    func snapshotPrecedesLaunchAndJournalCompletesAfterExit() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle(games: [1_279_510])
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let game = try #require(games.first)
        try Data("latest-local-save".utf8).write(
            to: game.installURL.appending(path: "saveables.dat")
        )
        let safetyRoot = bottle.url.appending(path: "Launch Safety Tests")
        let vaultURL = safetyRoot.appending(path: "Save Vault")
        let journalURL = safetyRoot.appending(path: "Transactions")
        let bottleID = BottleLaunchIdentity.id(for: bottle.url)
        let controller = SteamLaunchSafetyController(
            vault: SaveVault(rootURL: vaultURL),
            journal: LaunchTransactionJournal(rootURL: journalURL)
        )
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        let orchestrator = SteamClientOrchestrator(
            bottle: bottle,
            driver: driver,
            timing: SteamOrchestratorFixture.fast,
            launchSafety: controller
        )
        var snapshotWasPublishedAtLaunch = false
        driver.onLaunchGame = { _ in
            let gameVault = vaultURL.appending(path: "\(bottleID)/screw-drivers")
            let snapshots = try? FileManager.default.contentsOfDirectory(
                at: gameVault,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            snapshotWasPublishedAtLaunch = snapshots?.count == 1
            driver.script = [
                ["steam.exe", "game1.exe"],
                ["steam.exe"],
                ["steam.exe"]
            ]
        }

        orchestrator.launch(game)
        await SteamOrchestratorFixture.awaitIdle(orchestrator)
        await SteamOrchestratorFixture.eventually("exit monitoring should complete the journal") {
            transactionCompleted(in: journalURL)
        }

        #expect(snapshotWasPublishedAtLaunch)
        #expect(driver.launched == [game.appId])
        #expect(orchestrator.launchError == nil)
    }

    private func transactionCompleted(in journalURL: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: journalURL,
            includingPropertiesForKeys: nil
        ),
            let recordURL = files.first(where: { $0.pathExtension == "json" }),
            let data = try? Data(contentsOf: recordURL),
            let record = try? JSONDecoder.openBottleISO8601.decode(
                LaunchTransactionRecord.self,
                from: data
            )
        else { return false }
        return record.stage == .completed
    }
}

private extension JSONDecoder {
    static var openBottleISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
