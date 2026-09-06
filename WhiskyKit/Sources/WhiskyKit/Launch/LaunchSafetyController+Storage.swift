//
//  LaunchSafetyController+Storage.swift
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

extension LaunchSafetyController {
    func recordSavePlan(
        _ sources: [SaveSource],
        bottleURL: URL,
        bottleID: String,
        gameID: String,
        at date: Date
    ) throws {
        try saveSourcePlanStore.save(
            sources: sources,
            bottleURL: bottleURL,
            bottleID: bottleID,
            gameID: gameID,
            at: date
        )
    }

    func restoreConfiguration(_ preparation: LaunchSafetyPreparation) async throws {
        try await configurationStore.restore(
            bottleURL: preparation.bottleURL,
            bottleID: preparation.bottleID,
            gameID: preparation.gameID,
            snapshotID: preparation.transactionID.uuidString.lowercased(),
            operationID: preparation.transactionID
        )
    }

    func capturePostLaunchSaves(
        _ preparation: LaunchSafetyPreparation
    ) async throws -> SaveSnapshot? {
        guard !preparation.saveSources.isEmpty else { return nil }
        try saveSourcePlanStore.save(
            sources: preparation.saveSources,
            bottleURL: preparation.bottleURL,
            bottleID: preparation.bottleID,
            gameID: preparation.gameID
        )
        return try await Task.detached(priority: .utility) {
            try saveVault.capture(
                bottleID: preparation.bottleID,
                gameID: preparation.gameID,
                sources: preparation.saveSources,
                identifier: "post-\(preparation.transactionID.uuidString.lowercased())"
            )
        }.value
    }

    func releaseLease(_ preparation: LaunchSafetyPreparation) async throws {
        try await leaseStore.release(
            bottleID: preparation.bottleID,
            transactionID: preparation.transactionID
        )
    }

    func enforceRetention(
        _ record: LaunchTransactionRecord,
        preparation: LaunchSafetyPreparation
    ) throws {
        let protectedSaveSnapshotIDs = [
            record.saveSnapshotID,
            record.postLaunchSaveSnapshotID
        ].compactMap { $0 }
        if !protectedSaveSnapshotIDs.isEmpty {
            try saveVault.enforceRetention(
                bottleID: record.bottleID,
                gameID: record.gameID,
                maximumSnapshots: maximumSaveSnapshots,
                protectedSnapshotIDs: Set(protectedSaveSnapshotIDs)
            )
        }
        try configurationStore.enforceRetention(
            bottleID: preparation.bottleID,
            gameID: preparation.gameID,
            protectedSnapshotID: preparation.transactionID.uuidString.lowercased(),
            maximumSnapshots: maximumConfigurationSnapshots
        )
    }

    func preparation(
        for record: LaunchTransactionRecord,
        bottleURL: URL
    ) -> LaunchSafetyPreparation {
        let sources = (try? saveSourcePlanStore.load(
            bottleURL: bottleURL,
            bottleID: record.bottleID,
            gameID: record.gameID
        )) ?? []
        return LaunchSafetyPreparation(
            transactionID: record.id,
            bottleURL: bottleURL,
            bottleID: record.bottleID,
            gameID: record.gameID,
            saveSnapshot: nil,
            saveSources: sources
        )
    }
}
