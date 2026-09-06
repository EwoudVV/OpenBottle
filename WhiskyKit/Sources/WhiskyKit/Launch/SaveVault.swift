//
//  SaveVault.swift
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

/// Creates and verifies private, portable save restore points.
///
/// A snapshot is assembled in a hidden sibling directory and moved into place
/// only after every copied file and the manifest verify. A crash cannot expose a
/// half-written directory as a usable restore point.
public struct SaveVault: Sendable {
    public static let manifestFileName = "manifest.json"
    public static let payloadDirectoryName = "payload"

    public let rootURL: URL

    private struct CapturedSource {
        let source: SaveSnapshotManifest.SourceRecord
        let directories: [SaveSnapshotManifest.DirectoryRecord]
        let files: [SaveSnapshotManifest.FileRecord]
    }

    private struct CapturedDirectory {
        let directories: [SaveSnapshotManifest.DirectoryRecord]
        let files: [SaveSnapshotManifest.FileRecord]
    }

    private enum CapturedMember {
        case directory(SaveSnapshotManifest.DirectoryRecord)
        case file(SaveSnapshotManifest.FileRecord)
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Captures one game's concrete save sources.
    ///
    /// - Parameters:
    ///   - bottleID: Opaque identity for the bottle that owns this installation.
    ///   - gameID: Stable game identity, normally a GameDB ID or store/App ID.
    ///   - sources: Concrete files and directories resolved on this machine.
    ///   - createdAt: Injectable timestamp for deterministic tests.
    ///   - identifier: Injectable snapshot ID for deterministic tests.
    /// - Returns: A snapshot that has already passed ``verify(snapshotAt:)``.
    public func capture(
        bottleID: String,
        gameID: String,
        sources: [SaveSource],
        createdAt: Date = Date(),
        identifier: String = UUID().uuidString.lowercased()
    ) throws -> SaveSnapshot {
        try [bottleID, gameID, identifier].forEach(Self.validateIdentifier)
        try validate(sources: sources)

        let manager = FileManager.default
        let bottleURL = rootURL.appending(path: bottleID, directoryHint: .isDirectory)
        let gameURL = bottleURL.appending(path: gameID, directoryHint: .isDirectory)
        let finalURL = gameURL.appending(path: identifier, directoryHint: .isDirectory)
        let stagingURL = gameURL.appending(
            path: ".\(identifier).staging-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )

        guard !manager.fileExists(atPath: finalURL.path(percentEncoded: false)) else {
            throw SaveVaultError.snapshotAlreadyExists(identifier)
        }

        try manager.createDirectory(at: gameURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: false)

        var stagingNeedsRemoval = true
        defer {
            if stagingNeedsRemoval {
                try? manager.removeItem(at: stagingURL)
            }
        }

        let payloadURL = stagingURL.appending(
            path: Self.payloadDirectoryName,
            directoryHint: .isDirectory
        )
        try manager.createDirectory(at: payloadURL, withIntermediateDirectories: false)

        var sourceRecords: [SaveSnapshotManifest.SourceRecord] = []
        var directoryRecords: [SaveSnapshotManifest.DirectoryRecord] = []
        var fileRecords: [SaveSnapshotManifest.FileRecord] = []

        for source in sources.sorted(by: { $0.id < $1.id }) {
            let records = try capture(source: source, into: payloadURL)
            sourceRecords.append(records.source)
            directoryRecords.append(contentsOf: records.directories)
            fileRecords.append(contentsOf: records.files)
        }

        let manifest = SaveSnapshotManifest(
            id: identifier,
            bottleID: bottleID,
            gameID: gameID,
            createdAt: createdAt,
            sources: sourceRecords,
            directories: directoryRecords.sorted(by: Self.directoryRecordOrder),
            files: fileRecords.sorted(by: Self.fileRecordOrder)
        )
        try Self.write(manifest: manifest, to: stagingURL)
        _ = try verifyContents(at: stagingURL)

        try manager.moveItem(at: stagingURL, to: finalURL)
        stagingNeedsRemoval = false
        return try verify(snapshotAt: finalURL)
    }

    // MARK: - Capture

    private func capture(
        source: SaveSource,
        into payloadURL: URL
    ) throws -> CapturedSource {
        let manager = FileManager.default
        guard let sourceURL = try validatedURL(for: source) else {
            return Self.absentCapture(for: source)
        }

        let sourcePayloadURL = payloadURL.appending(path: source.id, directoryHint: .isDirectory)
        try manager.createDirectory(at: sourcePayloadURL, withIntermediateDirectories: false)
        let sourceRecord = SaveSnapshotManifest.SourceRecord(
            id: source.id,
            kind: source.kind,
            wasPresent: true
        )

        switch source.kind {
        case .file:
            let destination = sourcePayloadURL.appending(path: "file", directoryHint: .notDirectory)
            try manager.copyItem(at: sourceURL, to: destination)
            let record = try Self.fileRecord(
                sourceID: source.id,
                relativePath: "",
                payloadURL: destination
            )
            return CapturedSource(source: sourceRecord, directories: [], files: [record])

        case .directory:
            let rootPayloadURL = sourcePayloadURL.appending(path: "root", directoryHint: .isDirectory)
            try manager.createDirectory(at: rootPayloadURL, withIntermediateDirectories: false)
            let contents = try captureDirectory(
                sourceID: source.id,
                sourceURL: sourceURL,
                payloadURL: rootPayloadURL
            )
            return CapturedSource(
                source: sourceRecord,
                directories: contents.directories,
                files: contents.files
            )
        }
    }

    private func validatedURL(for source: SaveSource) throws -> URL? {
        let suppliedURL = source.url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: suppliedURL.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        else {
            if source.required {
                throw SaveVaultError.requiredSourceMissing(source.id)
            }
            return nil
        }
        if try Self.fileType(at: suppliedURL) == .typeSymbolicLink {
            throw SaveVaultError.symbolicLinkNotAllowed(source.id)
        }
        let sourceURL = suppliedURL.resolvingSymlinksInPath()
        guard isDirectory.boolValue == (source.kind == .directory) else {
            throw SaveVaultError.sourceTypeMismatch(source.id)
        }
        return sourceURL
    }

    private static func absentCapture(for source: SaveSource) -> CapturedSource {
        CapturedSource(
            source: SaveSnapshotManifest.SourceRecord(
                id: source.id,
                kind: source.kind,
                wasPresent: false
            ),
            directories: [],
            files: []
        )
    }

    private func captureDirectory(
        sourceID: String,
        sourceURL: URL,
        payloadURL: URL
    ) throws -> CapturedDirectory {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        )
        else {
            throw SaveVaultError.unsupportedSourceItem(sourceID)
        }

        var members: [URL] = []
        for case let member as URL in enumerator {
            members.append(member)
        }
        if enumerationError != nil {
            throw SaveVaultError.unsupportedSourceItem(sourceID)
        }

        var directories: [SaveSnapshotManifest.DirectoryRecord] = []
        var files: [SaveSnapshotManifest.FileRecord] = []
        for member in members.sorted(by: { $0.path < $1.path }) {
            switch try capture(
                member: member,
                sourceID: sourceID,
                sourceURL: sourceURL,
                payloadURL: payloadURL,
                resourceKeys: Set(keys)
            ) {
            case let .directory(record):
                directories.append(record)
            case let .file(record):
                files.append(record)
            }
        }
        return CapturedDirectory(directories: directories, files: files)
    }

    private func capture(
        member: URL,
        sourceID: String,
        sourceURL: URL,
        payloadURL: URL,
        resourceKeys: Set<URLResourceKey>
    ) throws -> CapturedMember {
        let relativePath = try Self.relativePath(of: member, below: sourceURL)
        let values = try member.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true {
            throw SaveVaultError.symbolicLinkNotAllowed("\(sourceID)/\(relativePath)")
        }

        let destination = payloadURL.appending(path: relativePath)
        if values.isDirectory == true {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            return .directory(SaveSnapshotManifest.DirectoryRecord(
                sourceID: sourceID,
                relativePath: relativePath
            ))
        }
        guard values.isRegularFile == true else {
            throw SaveVaultError.unsupportedSourceItem("\(sourceID)/\(relativePath)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: member, to: destination)
        return try .file(Self.fileRecord(
            sourceID: sourceID,
            relativePath: relativePath,
            payloadURL: destination
        ))
    }
}
