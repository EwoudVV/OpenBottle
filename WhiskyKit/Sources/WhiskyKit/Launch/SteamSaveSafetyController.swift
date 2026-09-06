//
//  SteamSaveSafetyController.swift
//  WhiskyKit
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

/// Lists, restores, and recovers Steam saves through the shared vault.
public struct SteamSaveSafetyController: Sendable {
    private let vault: SaveVault
    private let engine: SaveRestoreEngine
    private let entries: [GameDBEntry]
    private let wineUserName: String?
    private let maximumSnapshots: Int

    public init(
        vault: SaveVault,
        restoreJournal: SaveRestoreJournal,
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil,
        maximumSnapshots: Int = SaveVault.defaultMaximumSnapshots
    ) {
        self.vault = vault
        self.engine = SaveRestoreEngine(vault: vault, journal: restoreJournal)
        self.entries = entries
        self.wineUserName = wineUserName
        self.maximumSnapshots = max(1, maximumSnapshots)
    }

    public func hasSavePlan(for game: SteamGame) -> Bool {
        hasSavePlan(steamAppID: game.appId)
    }

    public func hasSavePlan(steamAppID: Int) -> Bool {
        entries.first { $0.steamAppId == steamAppID }?.saveLocations?.isEmpty == false
    }

    public func inventory(
        game: SteamGame,
        bottleURL: URL
    ) async throws -> SaveSnapshotInventory {
        let plan = try plan(for: game, bottleURL: bottleURL)
        return try vault.inventory(
            bottleID: BottleLaunchIdentity.id(for: bottleURL),
            gameID: plan.gameID
        )
    }

    public func restore(
        snapshot: SaveSnapshot,
        game: SteamGame,
        bottleURL: URL
    ) async throws -> SaveRestoreResult {
        let plan = try plan(for: game, bottleURL: bottleURL)
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        guard snapshot.manifest.bottleID == bottleID,
              snapshot.manifest.gameID == plan.gameID
        else {
            throw SaveRestoreError.snapshotScopeMismatch
        }
        let result = try await engine.restore(
            snapshotAt: snapshot.url,
            sources: plan.sources
        )
        _ = try? await Task.detached(priority: .utility) {
            try vault.enforceRetention(
                bottleID: bottleID,
                gameID: plan.gameID,
                maximumSnapshots: maximumSnapshots,
                protectedSnapshotIDs: [
                    result.restoredSnapshot.manifest.id,
                    result.rollbackSnapshot.manifest.id
                ]
            )
        }.value
        return result
    }

    /// Recovers idle games and leaves a running game's restore untouched until it exits.
    @discardableResult
    public func recoverUnfinished(
        bottleURL: URL,
        games: [SteamGame],
        runningAppIDs: Set<Int>
    ) async throws -> [SaveRestoreRecord] {
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        let records = try await engine.unfinished(bottleID: bottleID)
        var recovered: [SaveRestoreRecord] = []
        for record in records {
            guard let game = SteamGameSavePlanner.game(
                for: record.gameID,
                among: games,
                entries: entries
            )
            else { continue }
            guard !runningAppIDs.contains(game.appId) else { continue }
            let plan = try plan(for: game, bottleURL: bottleURL)
            try await recovered.append(engine.recover(record, sources: plan.sources))
        }
        return recovered
    }

    private func plan(for game: SteamGame, bottleURL: URL) throws -> SteamGameSavePlan {
        try SteamGameSavePlanner.resolve(
            game: game,
            bottleURL: bottleURL,
            entries: entries,
            wineUserName: wineUserName
        )
    }
}
