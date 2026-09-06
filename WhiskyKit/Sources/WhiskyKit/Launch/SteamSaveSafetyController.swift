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
    private let saveSourcePlanStore: SaveSourcePlanStore

    public init(
        vault: SaveVault,
        restoreJournal: SaveRestoreJournal,
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil,
        maximumSnapshots: Int = SaveVault.defaultMaximumSnapshots,
        saveSourcePlanStore: SaveSourcePlanStore? = nil
    ) {
        self.vault = vault
        self.engine = SaveRestoreEngine(vault: vault, journal: restoreJournal)
        self.entries = entries
        self.wineUserName = wineUserName
        self.maximumSnapshots = max(1, maximumSnapshots)
        self.saveSourcePlanStore = saveSourcePlanStore ?? SaveSourcePlanStore(
            rootURL: restoreJournal.rootURL.deletingLastPathComponent().appending(path: "Save Plans")
        )
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
        return try inventory(
            gameID: plan.gameID,
            bottleURL: bottleURL
        )
    }

    public func inventory(
        gameID: String,
        bottleURL: URL
    ) throws -> SaveSnapshotInventory {
        try vault.inventory(
            bottleID: BottleLaunchIdentity.id(for: bottleURL),
            gameID: gameID
        )
    }

    public func restore(
        snapshot: SaveSnapshot,
        game: SteamGame,
        bottleURL: URL
    ) async throws -> SaveRestoreResult {
        let plan = try plan(for: game, bottleURL: bottleURL)
        return try await restore(
            snapshot: snapshot,
            gameID: plan.gameID,
            sources: plan.sources,
            bottleURL: bottleURL
        )
    }

    public func restore(
        snapshot: SaveSnapshot,
        gameID: String,
        sources: [SaveSource],
        bottleURL: URL
    ) async throws -> SaveRestoreResult {
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        guard snapshot.manifest.bottleID == bottleID,
              snapshot.manifest.gameID == gameID
        else {
            throw SaveRestoreError.snapshotScopeMismatch
        }
        let restoreSources = try restorationSources(
            for: snapshot,
            suppliedSources: sources,
            bottleURL: bottleURL,
            bottleID: bottleID,
            gameID: gameID
        )
        let result = try await engine.restore(
            snapshotAt: snapshot.url,
            sources: restoreSources
        )
        _ = try? await Task.detached(priority: .utility) {
            try vault.enforceRetention(
                bottleID: bottleID,
                gameID: gameID,
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

    private func restorationSources(
        for snapshot: SaveSnapshot,
        suppliedSources: [SaveSource],
        bottleURL: URL,
        bottleID: String,
        gameID: String
    ) throws -> [SaveSource] {
        let persisted = try saveSourcePlanStore.load(
            bottleURL: bottleURL,
            bottleID: bottleID,
            gameID: gameID
        )
        var byID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        for source in suppliedSources {
            byID[source.id] = source
        }
        return try snapshot.manifest.sources.map { record in
            guard let source = byID[record.id] else {
                throw SaveRestoreError.sourcePlanMismatch(record.id)
            }
            return source
        }
    }
}
