//
//  SaveRestoreEngine.swift
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

/// Restores snapshots serially and leaves enough durable state to recover after a crash.
public actor SaveRestoreEngine {
    let vault: SaveVault
    let journal: SaveRestoreJournal

    public init(vault: SaveVault, journal: SaveRestoreJournal) {
        self.vault = vault
        self.journal = journal
    }

    /// Restores one verified snapshot after preserving the current live state.
    public func restore(
        snapshotAt snapshotURL: URL,
        sources: [SaveSource],
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) async throws -> SaveRestoreResult {
        let target = try vault.verify(snapshotAt: snapshotURL)
        _ = try vault.validateRestorePlan(snapshot: target, sources: sources)
        var record = try await journal.begin(
            bottleID: target.manifest.bottleID,
            gameID: target.manifest.gameID,
            targetSnapshotID: target.manifest.id,
            identifier: identifier,
            at: date
        )
        let rollbackID = "restore-\(identifier.uuidString.lowercased())-rollback"
        var rollback: SaveSnapshot?

        do {
            rollback = try vault.capture(
                bottleID: target.manifest.bottleID,
                gameID: target.manifest.gameID,
                sources: sources,
                createdAt: date,
                identifier: rollbackID
            )
            record = try await journal.advance(
                identifier,
                to: .rollbackCaptured,
                rollbackSnapshotID: rollbackID
            )
            let plan = try vault.stageRestore(
                snapshot: target,
                sources: sources,
                operationID: identifier
            )
            try vault.verifyRestoreTargets(snapshot: required(rollback), sources: sources)
            record = try await journal.advance(identifier, to: .prepared)
            record = try await journal.advance(identifier, to: .applying)
            try vault.applyRestore(plan)
            try vault.verifyRestoreTargets(snapshot: target, sources: sources)
            record = try await journal.advance(identifier, to: .cleaningUp)
            try vault.cleanupRestoreArtifacts(sources: sources, operationID: identifier)
            record = try await journal.advance(identifier, to: .completed)
            return try SaveRestoreResult(
                restoredSnapshot: target,
                rollbackSnapshot: required(rollback),
                record: record
            )
        } catch {
            try await handleRestoreFailure(
                recordID: record.id,
                sources: sources,
                originalError: error
            )
        }
    }

    /// Completes or rolls back one unfinished restore without creating another rollback point.
    public func recover(
        _ suppliedRecord: SaveRestoreRecord,
        sources: [SaveSource]
    ) async throws -> SaveRestoreRecord {
        var record = try await journal.record(for: suppliedRecord.id)
        switch record.stage {
        case .created, .rollbackCaptured, .prepared:
            try? vault.cleanupRestoreArtifacts(sources: sources, operationID: record.id)
            return try await journal.fail(record.id, code: "interrupted-before-apply")

        case .applying:
            record = try await journal.fail(record.id, code: "interrupted-restore")
            return try await recoverRollback(record, sources: sources)

        case .recoveryNeeded:
            return try await recoverRollback(record, sources: sources)

        case .cleaningUp:
            return try await finishInterruptedCleanup(record, sources: sources)

        case .completed, .failed:
            return record
        }
    }

    public func unfinished(bottleID: String? = nil) async throws -> [SaveRestoreRecord] {
        let records = try await journal.unfinished()
        guard let bottleID else { return records }
        return records.filter { $0.bottleID == bottleID }
    }

    private func handleRestoreFailure(
        recordID: UUID,
        sources: [SaveSource],
        originalError: Error
    ) async throws -> Never {
        let failed = try await journal.fail(recordID, code: "restore-failed")
        if failed.stage == .recoveryNeeded {
            do {
                _ = try await recoverRollback(failed, sources: sources)
            } catch {
                _ = try? await journal.fail(recordID, code: "rollback-retry-failed")
                throw SaveRestoreError.recoveryFailed("rollback-retry-failed")
            }
        } else {
            try? vault.cleanupRestoreArtifacts(sources: sources, operationID: recordID)
        }
        throw originalError
    }

    private func recoverRollback(
        _ record: SaveRestoreRecord,
        sources: [SaveSource]
    ) async throws -> SaveRestoreRecord {
        guard let rollbackID = record.rollbackSnapshotID else {
            throw SaveRestoreError.rollbackSnapshotMissing
        }
        let rollbackURL = try vault.snapshotURL(
            bottleID: record.bottleID,
            gameID: record.gameID,
            snapshotID: rollbackID
        )
        let rollback = try vault.verify(snapshotAt: rollbackURL)
        let plan = try vault.stageRestore(
            snapshot: rollback,
            sources: sources,
            operationID: record.id
        )
        try vault.applyRestore(plan)
        try vault.verifyRestoreTargets(snapshot: rollback, sources: sources)
        try vault.cleanupRestoreArtifacts(sources: sources, operationID: record.id)
        return try await journal.finishRecovery(record.id)
    }

    private func finishInterruptedCleanup(
        _ record: SaveRestoreRecord,
        sources: [SaveSource]
    ) async throws -> SaveRestoreRecord {
        do {
            let targetURL = try vault.snapshotURL(
                bottleID: record.bottleID,
                gameID: record.gameID,
                snapshotID: record.targetSnapshotID
            )
            let target = try vault.verify(snapshotAt: targetURL)
            try vault.verifyRestoreTargets(snapshot: target, sources: sources)
            try vault.cleanupRestoreArtifacts(sources: sources, operationID: record.id)
            return try await journal.advance(record.id, to: .completed)
        } catch {
            let failed = try await journal.fail(record.id, code: "cleanup-verification-failed")
            return try await recoverRollback(failed, sources: sources)
        }
    }

    private func required(_ snapshot: SaveSnapshot?) throws -> SaveSnapshot {
        guard let snapshot else { throw SaveRestoreError.rollbackSnapshotMissing }
        return snapshot
    }
}
