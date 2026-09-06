//
//  LaunchSafetyController.swift
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

/// Durable state returned before a launch changes its bottle.
public struct LaunchSafetyPreparation: Equatable, Sendable {
    public let transactionID: UUID
    public let bottleURL: URL
    public let bottleID: String
    public let gameID: String
    public let runtimeSelection: RuntimeSelection
    public let saveSnapshot: SaveSnapshot?
    public let saveSources: [SaveSource]

    public init(
        transactionID: UUID,
        bottleURL: URL,
        bottleID: String,
        gameID: String,
        runtimeSelection: RuntimeSelection,
        saveSnapshot: SaveSnapshot?,
        saveSources: [SaveSource]
    ) {
        self.transactionID = transactionID
        self.bottleURL = bottleURL
        self.bottleID = bottleID
        self.gameID = gameID
        self.runtimeSelection = runtimeSelection
        self.saveSnapshot = saveSnapshot
        self.saveSources = saveSources
    }
}

/// One launch transaction used by stores, programs, shortcuts, URLs, and the CLI.
public struct LaunchSafetyController: Sendable {
    let saveVault: SaveVault
    let journal: LaunchTransactionJournal
    let configurationStore: LaunchConfigurationStore
    let leaseStore: LaunchLeaseStore
    let saveSourcePlanStore: SaveSourcePlanStore
    let runtimeResolver: RuntimeResolver
    let maximumSaveSnapshots: Int
    let maximumConfigurationSnapshots: Int

    public init(
        saveVault: SaveVault,
        journal: LaunchTransactionJournal,
        configurationVault: SaveVault? = nil,
        configurationRestoreJournal: SaveRestoreJournal? = nil,
        leaseStore: LaunchLeaseStore? = nil,
        saveSourcePlanStore: SaveSourcePlanStore? = nil,
        runtimeResolver: RuntimeResolver? = nil,
        maximumSaveSnapshots: Int = SaveVault.defaultMaximumSnapshots,
        maximumConfigurationSnapshots: Int = LaunchConfigurationStore.defaultMaximumSnapshots
    ) {
        let safetyRoot = journal.rootURL.deletingLastPathComponent()
        let configurationVault = configurationVault ?? SaveVault(
            rootURL: safetyRoot.appending(path: "Configuration Vault")
        )
        let restoreJournal = configurationRestoreJournal ?? SaveRestoreJournal(
            rootURL: safetyRoot.appending(path: "Configuration Restore Transactions")
        )
        self.saveVault = saveVault
        self.journal = journal
        self.configurationStore = LaunchConfigurationStore(
            vault: configurationVault,
            restoreJournal: restoreJournal
        )
        self.leaseStore = leaseStore ?? LaunchLeaseStore(
            rootURL: safetyRoot.appending(path: "Leases")
        )
        self.saveSourcePlanStore = saveSourcePlanStore ?? SaveSourcePlanStore(
            rootURL: safetyRoot.appending(path: "Save Plans")
        )
        self.runtimeResolver = runtimeResolver ?? .live()
        self.maximumSaveSnapshots = max(1, maximumSaveSnapshots)
        self.maximumConfigurationSnapshots = max(1, maximumConfigurationSnapshots)
    }

    /// The shared on-disk controller used by the app and its embedded command.
    public static func live(
        safetyRoot: URL = WhiskyWineInstaller.applicationFolder.appending(path: "Launch Safety")
    ) -> LaunchSafetyController {
        LaunchSafetyController(
            saveVault: SaveVault(rootURL: safetyRoot.appending(path: "Save Vault")),
            journal: LaunchTransactionJournal(
                rootURL: safetyRoot.appending(path: "Transactions")
            ),
            configurationVault: SaveVault(
                rootURL: safetyRoot.appending(path: "Configuration Vault")
            ),
            configurationRestoreJournal: SaveRestoreJournal(
                rootURL: safetyRoot.appending(path: "Configuration Restore Transactions")
            )
        )
    }

    /// Opens the journal and captures known saves before any launch preparation.
    public func begin(
        bottleURL: URL,
        gameID: String,
        saveSources: [SaveSource],
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) async throws -> LaunchSafetyPreparation {
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        let runtimeSelection = try await selectRuntimeAndBeginRecord(
            bottleID: bottleID,
            gameID: gameID,
            identifier: identifier,
            at: date
        )

        do {
            _ = try await leaseStore.acquire(
                bottleID: bottleID,
                transactionID: identifier,
                at: date
            )
            try recordSavePlan(
                saveSources, bottleURL: bottleURL, bottleID: bottleID, gameID: gameID, at: date
            )
            _ = try await journal.advance(identifier, to: .preflightPassed, at: date)
            let snapshot = try await captureSaves(
                bottleID: bottleID,
                gameID: gameID,
                sources: saveSources,
                identifier: identifier,
                at: date
            )
            if let snapshot {
                _ = try await journal.advance(
                    identifier,
                    to: .saveCaptured,
                    saveSnapshotID: snapshot.manifest.id,
                    at: date
                )
            }
            return LaunchSafetyPreparation(
                transactionID: identifier,
                bottleURL: bottleURL,
                bottleID: bottleID,
                gameID: gameID,
                runtimeSelection: runtimeSelection,
                saveSnapshot: snapshot,
                saveSources: saveSources
            )
        } catch {
            try? await leaseStore.release(bottleID: bottleID, transactionID: identifier)
            _ = try? await journal.fail(
                identifier,
                code: Self.failureCode(for: error)
            )
            throw error
        }
    }

    /// Captures settings and renderer files immediately before the launch mutates them.
    @discardableResult
    public func prepareConfiguration(
        _ preparation: LaunchSafetyPreparation,
        at date: Date = Date()
    ) async throws -> LaunchTransactionRecord {
        do {
            _ = try await Task.detached(priority: .utility) {
                try configurationStore.capture(
                    bottleURL: preparation.bottleURL,
                    bottleID: preparation.bottleID,
                    gameID: preparation.gameID,
                    identifier: preparation.transactionID,
                    at: date
                )
            }.value
            return try await journal.advance(preparation.transactionID, to: .prepared, at: date)
        } catch {
            try? await leaseStore.release(
                bottleID: preparation.bottleID,
                transactionID: preparation.transactionID
            )
            _ = try? await journal.fail(preparation.transactionID, code: "configuration-capture-failed")
            throw error
        }
    }

    @discardableResult
    public func markLaunchRequested(
        _ preparation: LaunchSafetyPreparation
    ) async throws -> LaunchTransactionRecord {
        try await journal.advance(preparation.transactionID, to: .launchRequested)
    }

    @discardableResult
    public func markMonitoring(
        _ preparation: LaunchSafetyPreparation
    ) async throws -> LaunchTransactionRecord {
        try await journal.advance(preparation.transactionID, to: .monitoring)
    }

    @discardableResult
    public func fail(
        _ preparation: LaunchSafetyPreparation,
        code: String
    ) async throws -> LaunchTransactionRecord {
        let record = try await journal.fail(preparation.transactionID, code: code)
        if record.stage.isTerminal {
            try await releaseLease(preparation)
        }
        return record
    }

    @discardableResult
    public func finish(
        _ preparation: LaunchSafetyPreparation
    ) async throws -> LaunchTransactionRecord {
        var record = try await journal.record(for: preparation.transactionID)
        if record.stage == .launchRequested {
            record = try await journal.advance(record.id, to: .monitoring)
        }
        return try await finish(record, preparation: preparation)
    }

    public func unfinished(bottleURL: URL) async throws -> [LaunchTransactionRecord] {
        let bottleID = BottleLaunchIdentity.id(for: bottleURL)
        return try await journal.unfinished().filter { $0.bottleID == bottleID }
    }

    public func resumeMonitoring(
        _ record: LaunchTransactionRecord,
        bottleURL: URL
    ) async throws -> LaunchSafetyPreparation {
        let current = try await journal.record(for: record.id)
        if current.stage == .launchRequested {
            _ = try await journal.advance(record.id, to: .monitoring)
        }
        return preparation(for: current, bottleURL: bottleURL)
    }

    @discardableResult
    public func finishInterrupted(
        _ suppliedRecord: LaunchTransactionRecord,
        bottleURL: URL
    ) async throws -> LaunchTransactionRecord {
        let record = try await journal.record(for: suppliedRecord.id)
        let preparation = preparation(for: record, bottleURL: bottleURL)
        switch record.stage {
        case .created, .preflightPassed, .saveCaptured:
            try await releaseLease(preparation)
            return try await journal.fail(record.id, code: "interrupted-before-launch")
        case .prepared, .launchRequested:
            return try await finishFailure(record, preparation: preparation, code: "interrupted-launch")
        case .monitoring:
            return try await finishSuccess(record, preparation: preparation)
        case .recoveryNeeded:
            return try await finishFailure(
                record,
                preparation: preparation,
                code: record.failureCode ?? "interrupted-launch"
            )
        case .cleaningUp:
            try await restoreConfiguration(preparation)
            if record.failureCode == nil {
                try? recordRuntimeSuccess(preparation)
            }
            try await releaseLease(preparation)
            let terminal: LaunchTransactionStage = record.failureCode == nil ? .completed : .failed
            return try await journal.advance(record.id, to: terminal)
        case .completed, .failed:
            return record
        }
    }
}

private extension LaunchSafetyController {
    private func captureSaves(
        bottleID: String,
        gameID: String,
        sources: [SaveSource],
        identifier: UUID,
        at date: Date
    ) async throws -> SaveSnapshot? {
        guard !sources.isEmpty else { return nil }
        return try await Task.detached(priority: .utility) {
            try saveVault.capture(
                bottleID: bottleID,
                gameID: gameID,
                sources: sources,
                createdAt: date,
                identifier: identifier.uuidString.lowercased()
            )
        }.value
    }

    private func finish(
        _ record: LaunchTransactionRecord,
        preparation: LaunchSafetyPreparation
    ) async throws -> LaunchTransactionRecord {
        switch record.stage {
        case .monitoring:
            return try await finishSuccess(record, preparation: preparation)
        case .recoveryNeeded:
            return try await finishFailure(
                record,
                preparation: preparation,
                code: record.failureCode ?? "launch-failed"
            )
        case .cleaningUp:
            try await restoreConfiguration(preparation)
            if record.failureCode == nil {
                try? recordRuntimeSuccess(preparation)
            }
            try await releaseLease(preparation)
            let terminal: LaunchTransactionStage = record.failureCode == nil ? .completed : .failed
            return try await journal.advance(record.id, to: terminal)
        default:
            throw LaunchTransactionError.invalidTransition(from: record.stage, nextStage: .cleaningUp)
        }
    }

    private func finishSuccess(
        _ record: LaunchTransactionRecord,
        preparation: LaunchSafetyPreparation
    ) async throws -> LaunchTransactionRecord {
        let postLaunchSnapshot: SaveSnapshot?
        do {
            postLaunchSnapshot = try await capturePostLaunchSaves(preparation)
        } catch {
            return try await finishFailure(
                record,
                preparation: preparation,
                code: "post-launch-save-capture-failed"
            )
        }
        _ = try await journal.advance(
            record.id,
            to: .cleaningUp,
            postLaunchSaveSnapshotID: postLaunchSnapshot?.manifest.id
        )
        do {
            try await restoreConfiguration(preparation)
            try? recordRuntimeSuccess(preparation)
            try await releaseLease(preparation)
            let completed = try await journal.advance(record.id, to: .completed)
            try? enforceRetention(completed, preparation: preparation)
            return completed
        } catch {
            _ = try? await journal.fail(record.id, code: "configuration-restore-failed")
            throw error
        }
    }

    private func finishFailure(
        _ suppliedRecord: LaunchTransactionRecord,
        preparation: LaunchSafetyPreparation,
        code: String
    ) async throws -> LaunchTransactionRecord {
        var record = suppliedRecord
        if record.stage != .recoveryNeeded {
            record = try await journal.fail(record.id, code: code)
        }
        _ = try await journal.advance(record.id, to: .cleaningUp)
        do {
            try await restoreConfiguration(preparation)
            try await releaseLease(preparation)
            let failed = try await journal.advance(record.id, to: .failed)
            try? enforceRetention(failed, preparation: preparation)
            return failed
        } catch {
            _ = try? await journal.fail(record.id, code: "configuration-restore-failed")
            throw error
        }
    }
}
