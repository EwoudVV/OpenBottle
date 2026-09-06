//
//  SaveVault+Verification.swift
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
    private struct ExpectedPayload {
        let files: Set<String>
        let directories: Set<String>
    }

    private struct VerifiedFiles {
        let paths: Set<String>
        let countsBySource: [String: Int]
    }

    /// Verifies manifest structure, payload membership, byte counts, and SHA-256 hashes.
    public func verify(snapshotAt snapshotURL: URL) throws -> SaveSnapshot {
        let standardizedSnapshot = snapshotURL.standardizedFileURL
        if try Self.fileType(at: standardizedSnapshot) == .typeSymbolicLink {
            throw SaveVaultError.symbolicLinkNotAllowed(standardizedSnapshot.lastPathComponent)
        }
        let resolvedSnapshot = standardizedSnapshot.resolvingSymlinksInPath()
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        guard Self.isDescendant(resolvedSnapshot, of: resolvedRoot),
              resolvedSnapshot != resolvedRoot
        else {
            throw SaveVaultError.snapshotOutsideVault
        }

        let snapshot = try verifyContents(at: resolvedSnapshot)
        guard snapshot.manifest.id == resolvedSnapshot.lastPathComponent else {
            throw SaveVaultError.invalidManifest("snapshot ID does not match its directory")
        }
        guard snapshot.manifest.gameID == resolvedSnapshot.deletingLastPathComponent().lastPathComponent else {
            throw SaveVaultError.invalidManifest("game ID does not match its directory")
        }
        let bottleURL = resolvedSnapshot.deletingLastPathComponent().deletingLastPathComponent()
        guard snapshot.manifest.bottleID == bottleURL.lastPathComponent else {
            throw SaveVaultError.invalidManifest("bottle ID does not match its directory")
        }
        guard Self.normalizedPath(bottleURL.deletingLastPathComponent())
            == Self.normalizedPath(resolvedRoot)
        else {
            throw SaveVaultError.snapshotOutsideVault
        }
        return snapshot
    }

    func verifyContents(at snapshotURL: URL) throws -> SaveSnapshot {
        try validateSnapshotLayout(at: snapshotURL)
        let manifest = try loadManifest(from: snapshotURL)
        let sourcesByID = try sourceRecordsByID(in: manifest)
        let payloadURL = snapshotURL.appending(
            path: Self.payloadDirectoryName,
            directoryHint: .isDirectory
        )
        let expected = try expectedPayload(
            for: manifest,
            sourcesByID: sourcesByID,
            payloadURL: payloadURL
        )
        let actual = try Self.payloadContents(below: payloadURL)
        try compare(actual: actual, expected: expected)
        return SaveSnapshot(url: snapshotURL, manifest: manifest)
    }

    private func validateSnapshotLayout(at snapshotURL: URL) throws {
        guard try Self.fileType(at: snapshotURL) == .typeDirectory else {
            throw SaveVaultError.invalidManifest("snapshot is not a directory")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: nil
        )
        let allowedChildren = Set([Self.manifestFileName, Self.payloadDirectoryName])
        if let unexpected = children
            .map(\.lastPathComponent)
            .filter({ !allowedChildren.contains($0) })
            .sorted()
            .first {
            throw SaveVaultError.unexpectedPayload(unexpected)
        }
    }

    private func loadManifest(from snapshotURL: URL) throws -> SaveSnapshotManifest {
        let manifestURL = snapshotURL.appending(
            path: Self.manifestFileName,
            directoryHint: .notDirectory
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw SaveVaultError.manifestMissing
        }
        if try Self.fileType(at: manifestURL) == .typeSymbolicLink {
            throw SaveVaultError.symbolicLinkNotAllowed(Self.manifestFileName)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: SaveSnapshotManifest
        do {
            manifest = try decoder.decode(
                SaveSnapshotManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw SaveVaultError.invalidManifest("cannot decode manifest")
        }
        guard manifest.schemaVersion == SaveSnapshotManifest.currentSchemaVersion else {
            throw SaveVaultError.unsupportedSchema(manifest.schemaVersion)
        }
        try Self.validateIdentifier(manifest.id)
        try Self.validateIdentifier(manifest.bottleID)
        try Self.validateIdentifier(manifest.gameID)
        return manifest
    }

    private func sourceRecordsByID(
        in manifest: SaveSnapshotManifest
    ) throws -> [String: SaveSnapshotManifest.SourceRecord] {
        var result: [String: SaveSnapshotManifest.SourceRecord] = [:]
        for source in manifest.sources {
            try Self.validateIdentifier(source.id)
            guard result[source.id] == nil else {
                throw SaveVaultError.invalidManifest("duplicate source ID \(source.id)")
            }
            result[source.id] = source
        }
        return result
    }

    private func expectedPayload(
        for manifest: SaveSnapshotManifest,
        sourcesByID: [String: SaveSnapshotManifest.SourceRecord],
        payloadURL: URL
    ) throws -> ExpectedPayload {
        let directories = try expectedDirectories(
            in: manifest,
            sourcesByID: sourcesByID
        )
        let verifiedFiles = try verifyFiles(
            in: manifest,
            sourcesByID: sourcesByID,
            payloadURL: payloadURL
        )
        try validateSourceFileCounts(
            manifest.sources,
            countsBySource: verifiedFiles.countsBySource
        )
        return ExpectedPayload(files: verifiedFiles.paths, directories: directories)
    }

    private func expectedDirectories(
        in manifest: SaveSnapshotManifest,
        sourcesByID: [String: SaveSnapshotManifest.SourceRecord]
    ) throws -> Set<String> {
        var result = Set<String>()
        for source in manifest.sources where source.wasPresent {
            result.insert(source.id)
            if source.kind == .directory {
                result.insert("\(source.id)/root")
            }
        }

        for directory in manifest.directories {
            guard let source = sourcesByID[directory.sourceID],
                  source.wasPresent,
                  source.kind == .directory
            else {
                throw SaveVaultError.invalidManifest("directory references an invalid source")
            }
            try Self.validate(relativePath: directory.relativePath, for: .directory)
            let payloadPath = "\(directory.sourceID)/root/\(directory.relativePath)"
            guard result.insert(payloadPath).inserted else {
                throw SaveVaultError.invalidManifest("duplicate payload path \(payloadPath)")
            }
        }
        return result
    }

    private func verifyFiles(
        in manifest: SaveSnapshotManifest,
        sourcesByID: [String: SaveSnapshotManifest.SourceRecord],
        payloadURL: URL
    ) throws -> VerifiedFiles {
        var paths = Set<String>()
        var countsBySource: [String: Int] = [:]
        for file in manifest.files {
            guard let source = sourcesByID[file.sourceID], source.wasPresent else {
                throw SaveVaultError.invalidManifest("file references an absent source")
            }
            try Self.validate(relativePath: file.relativePath, for: source.kind)
            let payloadPath = Self.payloadPath(for: file, sourceKind: source.kind)
            guard paths.insert(payloadPath).inserted else {
                throw SaveVaultError.invalidManifest("duplicate payload path \(payloadPath)")
            }
            try verify(file: file, at: payloadURL.appending(path: payloadPath), payloadPath: payloadPath)
            countsBySource[file.sourceID, default: 0] += 1
        }
        return VerifiedFiles(paths: paths, countsBySource: countsBySource)
    }

    private func verify(
        file: SaveSnapshotManifest.FileRecord,
        at fileURL: URL,
        payloadPath: String
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw SaveVaultError.payloadMissing(payloadPath)
        }
        guard try Self.fileType(at: fileURL) == .typeRegular else {
            throw SaveVaultError.unsupportedSourceItem(payloadPath)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path(percentEncoded: false)
        )
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == file.byteCount else {
            throw SaveVaultError.byteCountMismatch(payloadPath)
        }
        guard try Self.sha256(of: fileURL) == file.sha256 else {
            throw SaveVaultError.checksumMismatch(payloadPath)
        }
    }

    private func validateSourceFileCounts(
        _ sources: [SaveSnapshotManifest.SourceRecord],
        countsBySource: [String: Int]
    ) throws {
        for source in sources {
            let count = countsBySource[source.id, default: 0]
            if !source.wasPresent, count != 0 {
                throw SaveVaultError.invalidManifest("absent source has payload")
            }
            if source.wasPresent, source.kind == .file, count != 1 {
                throw SaveVaultError.invalidManifest("file source must contain one file")
            }
        }
    }

    private func compare(
        actual: (files: Set<String>, directories: Set<String>),
        expected: ExpectedPayload
    ) throws {
        if let unexpected = actual.files.subtracting(expected.files).sorted().first {
            throw SaveVaultError.unexpectedPayload(unexpected)
        }
        if let missing = expected.files.subtracting(actual.files).sorted().first {
            throw SaveVaultError.payloadMissing(missing)
        }
        if let unexpected = actual.directories.subtracting(expected.directories).sorted().first {
            throw SaveVaultError.unexpectedPayload(unexpected)
        }
        if let missing = expected.directories.subtracting(actual.directories).sorted().first {
            throw SaveVaultError.payloadMissing(missing)
        }
    }
}
