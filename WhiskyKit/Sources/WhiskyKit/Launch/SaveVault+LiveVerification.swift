//
//  SaveVault+LiveVerification.swift
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

extension SaveVault {
    /// Verifies both the stored snapshot and the concrete save targets against it.
    @discardableResult
    public func verifyRestoreTargets(
        snapshotAt snapshotURL: URL,
        sources: [SaveSource]
    ) throws -> SaveSnapshot {
        let snapshot = try verify(snapshotAt: snapshotURL)
        try verifyRestoreTargets(snapshot: snapshot, sources: sources)
        return snapshot
    }

    func verifyRestoreTargets(
        snapshot: SaveSnapshot,
        sources: [SaveSource]
    ) throws {
        let sourceMap = try validateRestorePlan(snapshot: snapshot, sources: sources)
        for record in snapshot.manifest.sources {
            let source = try restoreSource(record.id, from: sourceMap)
            try verifyRestoreSource(
                record,
                manifest: snapshot.manifest,
                at: restoreTargetURL(for: source)
            )
        }
    }

    func validateRestorePlan(
        snapshot: SaveSnapshot,
        sources: [SaveSource]
    ) throws -> [String: SaveSource] {
        try validate(sources: sources)
        guard snapshot.manifest.sources.count == sources.count else {
            throw SaveRestoreError.sourcePlanMismatch("source-count")
        }
        let sourceMap = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for source in sources {
            let target = restoreTargetURL(for: source)
            guard target.pathComponents.count > 1,
                  !target.lastPathComponent.isEmpty,
                  target.lastPathComponent != "/"
            else {
                throw SaveRestoreError.sourcePlanMismatch(source.id)
            }
        }
        for record in snapshot.manifest.sources {
            guard let source = sourceMap[record.id], source.kind == record.kind else {
                throw SaveRestoreError.sourcePlanMismatch(record.id)
            }
        }
        return sourceMap
    }

    func verifyRestoreSource(
        _ sourceRecord: SaveSnapshotManifest.SourceRecord,
        manifest: SaveSnapshotManifest,
        at targetURL: URL
    ) throws {
        let itemType = try existingItemType(at: targetURL)
        guard sourceRecord.wasPresent else {
            guard itemType == nil else {
                throw SaveRestoreError.liveStateMismatch(sourceRecord.id)
            }
            return
        }
        guard itemType != .typeSymbolicLink else {
            throw SaveRestoreError.targetSymbolicLink(sourceRecord.id)
        }
        let expectedType: FileAttributeType = sourceRecord.kind == .file ? .typeRegular : .typeDirectory
        guard itemType == expectedType else {
            throw SaveRestoreError.liveStateMismatch(sourceRecord.id)
        }

        switch sourceRecord.kind {
        case .file:
            try verifyRestoreFile(sourceRecord, manifest: manifest, at: targetURL)
        case .directory:
            try verifyRestoreDirectory(sourceRecord, manifest: manifest, at: targetURL)
        }
    }

    func restoreTargetURL(for source: SaveSource) -> URL {
        let supplied = source.url.standardizedFileURL
        let parent = supplied.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appending(path: supplied.lastPathComponent)
    }

    private func verifyRestoreFile(
        _ source: SaveSnapshotManifest.SourceRecord,
        manifest: SaveSnapshotManifest,
        at targetURL: URL
    ) throws {
        let records = manifest.files.filter { $0.sourceID == source.id }
        guard records.count == 1, let record = records.first else {
            throw SaveRestoreError.sourcePlanMismatch(source.id)
        }
        try verifyLiveFile(record, at: targetURL, sourceID: source.id)
    }

    private func verifyRestoreDirectory(
        _ source: SaveSnapshotManifest.SourceRecord,
        manifest: SaveSnapshotManifest,
        at targetURL: URL
    ) throws {
        let actual = try Self.payloadContents(below: targetURL)
        let directoryRecords = manifest.directories.filter { $0.sourceID == source.id }
        let fileRecords = manifest.files.filter { $0.sourceID == source.id }
        let expectedDirectories = Set(directoryRecords.map(\.relativePath))
        let expectedFiles = Set(fileRecords.map(\.relativePath))
        guard actual.directories == expectedDirectories, actual.files == expectedFiles else {
            throw SaveRestoreError.liveStateMismatch(source.id)
        }
        for record in fileRecords {
            try verifyLiveFile(
                record,
                at: targetURL.appending(path: record.relativePath),
                sourceID: source.id
            )
        }
    }

    private func verifyLiveFile(
        _ record: SaveSnapshotManifest.FileRecord,
        at targetURL: URL,
        sourceID: String
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: targetURL.path(percentEncoded: false)
        )
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == record.byteCount,
              try Self.sha256(of: targetURL) == record.sha256
        else {
            throw SaveRestoreError.liveStateMismatch(sourceID)
        }
    }

    func existingItemType(at url: URL) throws -> FileAttributeType? {
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path(percentEncoded: false)
            )
            return attributes[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
