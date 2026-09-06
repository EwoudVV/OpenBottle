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
    private let maximumSnapshots: Int

    public init(
        vault: SaveVault,
        journal: LaunchTransactionJournal,
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil,
        maximumSnapshots: Int = SaveVault.defaultMaximumSnapshots
    ) {
        self.vault = vault
        self.journal = journal
        self.entries = entries
        self.wineUserName = wineUserName
        self.maximumSnapshots = max(1, maximumSnapshots)
    }

    /// Opens a journal record and captures every known save source before Steam starts.
    public func prepare(
        game: SteamGame,
        bottleURL: URL,
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) async throws -> SteamLaunchPreparation {
        let plan = try SteamGameSavePlanner.resolve(
            game: game,
            bottleURL: bottleURL,
            entries: entries,
            wineUserName: wineUserName
        )
        let gameID = plan.gameID
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        _ = try await journal.begin(
            bottleID: bottleID,
            gameID: gameID,
            identifier: identifier,
            at: date
        )

        do {
            _ = try await journal.advance(identifier, to: .preflightPassed, at: date)
            guard !plan.sources.isEmpty else {
                return SteamLaunchPreparation(transactionID: identifier, saveSnapshot: nil)
            }
            let snapshotID = identifier.uuidString.lowercased()
            let snapshot = try await Task.detached(priority: .utility) {
                try vault.capture(
                    bottleID: bottleID,
                    gameID: gameID,
                    sources: plan.sources,
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
        try await finishAfterExit(preparation)
    }

    public func unfinished(bottleURL: URL) async throws -> [LaunchTransactionRecord] {
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        return try await journal.unfinished().filter { $0.bottleID == bottleID }
    }

    func game(
        for record: LaunchTransactionRecord,
        among games: [SteamGame]
    ) -> SteamGame? {
        SteamGameSavePlanner.game(for: record.gameID, among: games, entries: entries)
    }

    func resumeMonitoring(
        _ record: LaunchTransactionRecord
    ) async throws -> SteamLaunchPreparation {
        let current = try await journal.record(for: record.id)
        if current.stage == .launchRequested {
            _ = try await journal.advance(record.id, to: .monitoring)
        }
        return SteamLaunchPreparation(transactionID: record.id, saveSnapshot: nil)
    }

    @discardableResult
    func finishInterrupted(
        _ suppliedRecord: LaunchTransactionRecord
    ) async throws -> LaunchTransactionRecord {
        let record = try await journal.record(for: suppliedRecord.id)
        switch record.stage {
        case .created, .preflightPassed, .saveCaptured:
            return try await journal.fail(record.id, code: "interrupted-before-launch")
        case .prepared, .launchRequested:
            return try await finishFailure(record, code: "interrupted-launch")
        case .monitoring:
            return try await finishSuccess(record)
        case .recoveryNeeded:
            return try await finishFailure(record, code: record.failureCode ?? "interrupted-launch")
        case .cleaningUp:
            let terminal: LaunchTransactionStage = record.failureCode == nil ? .completed : .failed
            return try await journal.advance(record.id, to: terminal)
        case .completed, .failed:
            return record
        }
    }

    @discardableResult
    func finishAfterExit(
        _ preparation: SteamLaunchPreparation
    ) async throws -> LaunchTransactionRecord {
        var record = try await journal.record(for: preparation.transactionID)
        if record.stage == .launchRequested {
            record = try await journal.advance(record.id, to: .monitoring)
        }
        switch record.stage {
        case .monitoring:
            return try await finishSuccess(record)
        case .recoveryNeeded:
            return try await finishFailure(record, code: record.failureCode ?? "launch-failed")
        case .cleaningUp:
            let terminal: LaunchTransactionStage = record.failureCode == nil ? .completed : .failed
            return try await journal.advance(record.id, to: terminal)
        default:
            throw LaunchTransactionError.invalidTransition(from: record.stage, nextStage: .cleaningUp)
        }
    }

    private func finishSuccess(
        _ record: LaunchTransactionRecord
    ) async throws -> LaunchTransactionRecord {
        _ = try await journal.advance(record.id, to: .cleaningUp)
        let completed = try await journal.advance(record.id, to: .completed)
        if let snapshotID = completed.saveSnapshotID {
            _ = try? await Task.detached(priority: .utility) {
                try vault.enforceRetention(
                    bottleID: completed.bottleID,
                    gameID: completed.gameID,
                    maximumSnapshots: maximumSnapshots,
                    protectedSnapshotIDs: [snapshotID]
                )
            }.value
        }
        return completed
    }

    private func finishFailure(
        _ suppliedRecord: LaunchTransactionRecord,
        code: String
    ) async throws -> LaunchTransactionRecord {
        var record = suppliedRecord
        if record.stage != .recoveryNeeded {
            record = try await journal.fail(record.id, code: code)
        }
        _ = try await journal.advance(record.id, to: .cleaningUp)
        return try await journal.advance(record.id, to: .failed)
    }
}
