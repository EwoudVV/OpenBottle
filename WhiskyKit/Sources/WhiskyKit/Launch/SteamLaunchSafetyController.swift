//
//  SteamLaunchSafetyController.swift
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

/// The durable transaction and optional pre-launch save snapshot for one game.
public struct SteamLaunchPreparation: Equatable, Sendable {
    public let transactionID: UUID
    public let saveSnapshot: SaveSnapshot?

    public init(transactionID: UUID, saveSnapshot: SaveSnapshot?) {
        self.transactionID = transactionID
        self.saveSnapshot = saveSnapshot
    }
}

/// Connects Steam game identity and GameDB save plans to the shared safety core.
public struct SteamLaunchSafetyController: Sendable {
    private let vault: SaveVault
    private let journal: LaunchTransactionJournal
    private let entries: [GameDBEntry]
    private let wineUserName: String?

    public init(
        vault: SaveVault,
        journal: LaunchTransactionJournal,
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil
    ) {
        self.vault = vault
        self.journal = journal
        self.entries = entries
        self.wineUserName = wineUserName
    }

    /// Opens a journal record and captures every known save source before Steam starts.
    public func prepare(
        game: SteamGame,
        bottleURL: URL,
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) async throws -> SteamLaunchPreparation {
        let entry = entries.first { $0.steamAppId == game.appId }
        let gameID = entry?.id ?? "steam-\(game.appId)"
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        _ = try await journal.begin(
            bottleID: bottleID,
            gameID: gameID,
            identifier: identifier,
            at: date
        )

        do {
            _ = try await journal.advance(identifier, to: .preflightPassed, at: date)
            let locations = entry?.saveLocations ?? []
            guard !locations.isEmpty else {
                return SteamLaunchPreparation(transactionID: identifier, saveSnapshot: nil)
            }

            let sources = try GameSaveResolver.resolve(
                locations,
                context: GameSaveContext(
                    bottleURL: bottleURL,
                    gameInstallURL: game.installURL,
                    wineUserName: wineUserName
                )
            )
            let snapshotID = identifier.uuidString.lowercased()
            let snapshot = try await Task.detached(priority: .utility) {
                try vault.capture(
                    bottleID: bottleID,
                    gameID: gameID,
                    sources: sources,
                    createdAt: date,
                    identifier: snapshotID
                )
            }.value
            _ = try await journal.advance(
                identifier,
                to: .saveCaptured,
                saveSnapshotID: snapshot.manifest.id,
                at: date
            )
            return SteamLaunchPreparation(transactionID: identifier, saveSnapshot: snapshot)
        } catch {
            _ = try? await journal.fail(identifier, code: "save-capture-failed")
            throw error
        }
    }

    @discardableResult
    public func markPrepared(_ preparation: SteamLaunchPreparation) async throws -> LaunchTransactionRecord {
        try await journal.advance(preparation.transactionID, to: .prepared)
    }

    @discardableResult
    public func markLaunchRequested(
        _ preparation: SteamLaunchPreparation
    ) async throws -> LaunchTransactionRecord {
        try await journal.advance(preparation.transactionID, to: .launchRequested)
    }

    @discardableResult
    public func markMonitoring(_ preparation: SteamLaunchPreparation) async throws -> LaunchTransactionRecord {
        try await journal.advance(preparation.transactionID, to: .monitoring)
    }

    /// Records a failure. Post-prepare failures remain recoverable in the journal.
    @discardableResult
    public func fail(
        _ preparation: SteamLaunchPreparation,
        code: String
    ) async throws -> LaunchTransactionRecord {
        try await journal.fail(preparation.transactionID, code: code)
    }

    /// Closes a successful transaction after the actual game process exits.
    @discardableResult
    public func complete(_ preparation: SteamLaunchPreparation) async throws -> LaunchTransactionRecord {
        _ = try await journal.advance(preparation.transactionID, to: .cleaningUp)
        return try await journal.advance(preparation.transactionID, to: .completed)
    }
}
