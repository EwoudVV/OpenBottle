//
//  SaveVault+Restore.swift
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

struct SaveRestoreSourcePlan: Sendable {
    let source: SaveSource
    let sourceRecord: SaveSnapshotManifest.SourceRecord
    let targetURL: URL
    let stagedURL: URL
    let replacedURL: URL
}

extension SaveVault {
    func stageRestore(
        snapshot: SaveSnapshot,
        sources: [SaveSource],
        operationID: UUID
    ) throws -> [SaveRestoreSourcePlan] {
        let sourceMap = try validateRestorePlan(snapshot: snapshot, sources: sources)
        let attemptID = UUID().uuidString.lowercased()
        let plans = try snapshot.manifest.sources.enumerated().map { index, record in
            let source = try restoreSource(record.id, from: sourceMap)
            return restorePlan(
                source: source,
                sourceRecord: record,
                index: index,
                operationID: operationID,
                attemptID: attemptID
            )
        }
        for plan in plans where plan.sourceRecord.wasPresent {
            try stageRestoreSource(plan, snapshot: snapshot)
        }
        return plans
    }

    func applyRestore(_ plans: [SaveRestoreSourcePlan]) throws {
        let manager = FileManager.default
        for plan in plans {
            let itemType = try existingItemType(at: plan.targetURL)
            guard itemType != .typeSymbolicLink else {
                throw SaveRestoreError.targetSymbolicLink(plan.source.id)
            }
            if itemType != nil {
                try manager.moveItem(at: plan.targetURL, to: plan.replacedURL)
            }
            if plan.sourceRecord.wasPresent {
                try manager.moveItem(at: plan.stagedURL, to: plan.targetURL)
            }
        }
    }

    func cleanupRestoreArtifacts(
        sources: [SaveSource],
        operationID: UUID
    ) throws {
        let manager = FileManager.default
        let prefix = restoreArtifactPrefix(operationID)
        let parents = Set(sources.map { restoreTargetURL(for: $0).deletingLastPathComponent() })
        for parent in parents {
            guard manager.fileExists(atPath: parent.path(percentEncoded: false)) else { continue }
            let children = try manager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            )
            for child in children where child.lastPathComponent.hasPrefix(prefix) {
                try manager.removeItem(at: child)
            }
        }
    }

    private func restorePlan(
        source: SaveSource,
        sourceRecord: SaveSnapshotManifest.SourceRecord,
        index: Int,
        operationID: UUID,
        attemptID: String
    ) -> SaveRestoreSourcePlan {
        let targetURL = restoreTargetURL(for: source)
        let parent = targetURL.deletingLastPathComponent()
        let base = "\(restoreArtifactPrefix(operationID))\(index)-\(attemptID)"
        return SaveRestoreSourcePlan(
            source: source,
            sourceRecord: sourceRecord,
            targetURL: targetURL,
            stagedURL: parent.appending(path: "\(base)-new"),
            replacedURL: parent.appending(path: "\(base)-old")
        )
    }

    private func stageRestoreSource(
        _ plan: SaveRestoreSourcePlan,
        snapshot: SaveSnapshot
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: plan.stagedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourcePayload = payloadURL(
            for: plan.sourceRecord,
            snapshotURL: snapshot.url
        )
        try manager.copyItem(at: sourcePayload, to: plan.stagedURL)
        try verifyRestoreSource(
            plan.sourceRecord,
            manifest: snapshot.manifest,
            at: plan.stagedURL
        )
    }

    private func payloadURL(
        for source: SaveSnapshotManifest.SourceRecord,
        snapshotURL: URL
    ) -> URL {
        let sourceRoot = snapshotURL
            .appending(path: Self.payloadDirectoryName)
            .appending(path: source.id)
        return switch source.kind {
        case .file:
            sourceRoot.appending(path: "file")
        case .directory:
            sourceRoot.appending(path: "root")
        }
    }

    private func restoreArtifactPrefix(_ operationID: UUID) -> String {
        ".openbottle-restore-\(operationID.uuidString.lowercased())-"
    }

    func restoreSource(
        _ identifier: String,
        from sourceMap: [String: SaveSource]
    ) throws -> SaveSource {
        guard let source = sourceMap[identifier] else {
            throw SaveRestoreError.sourcePlanMismatch(identifier)
        }
        return source
    }
}
