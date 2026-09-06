//
//  SaveSnapshot.swift
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

/// Whether one save source is a single file or a directory tree.
public enum SaveSourceKind: String, Codable, Equatable, Sendable {
    case file
    case directory
}

/// One concrete save location to capture.
///
/// `id` is persisted in the snapshot instead of `url`, so a shared report never
/// exposes a home directory or account name. Restore code resolves the ID back to
/// a current machine path.
public struct SaveSource: Equatable, Sendable {
    /// Stable name within one game's save plan.
    public let id: String
    /// Local file or directory to capture.
    public let url: URL
    /// The expected type, including when an optional source does not exist yet.
    public let kind: SaveSourceKind
    /// Whether capture must fail when the source is absent.
    public let required: Bool

    public init(id: String, url: URL, kind: SaveSourceKind, required: Bool = false) {
        self.id = id
        self.url = url
        self.kind = kind
        self.required = required
    }
}

/// Portable description of one verified save snapshot.
public struct SaveSnapshotManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    /// Format version for forward-compatible decoding.
    public let schemaVersion: Int
    /// Snapshot directory name.
    public let id: String
    /// Opaque identity of the bottle this save came from.
    public let bottleID: String
    /// Stable GameDB or library identity.
    public let gameID: String
    /// When capture began.
    public let createdAt: Date
    /// Sources in the save plan, including optional sources that were absent.
    public let sources: [SourceRecord]
    /// Directory structure below directory sources, including empty directories.
    public let directories: [DirectoryRecord]
    /// Every regular file in the snapshot payload.
    public let files: [FileRecord]

    public init(
        schemaVersion: Int = SaveSnapshotManifest.currentSchemaVersion,
        id: String,
        bottleID: String,
        gameID: String,
        createdAt: Date,
        sources: [SourceRecord],
        directories: [DirectoryRecord] = [],
        files: [FileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.bottleID = bottleID
        self.gameID = gameID
        self.createdAt = createdAt
        self.sources = sources
        self.directories = directories
        self.files = files
    }

    /// One source as it existed during capture.
    public struct SourceRecord: Codable, Equatable, Sendable {
        public let id: String
        public let kind: SaveSourceKind
        public let wasPresent: Bool

        public init(id: String, kind: SaveSourceKind, wasPresent: Bool) {
            self.id = id
            self.kind = kind
            self.wasPresent = wasPresent
        }
    }

    /// One directory below a directory source.
    public struct DirectoryRecord: Codable, Equatable, Sendable {
        public let sourceID: String
        public let relativePath: String

        public init(sourceID: String, relativePath: String) {
            self.sourceID = sourceID
            self.relativePath = relativePath
        }
    }

    /// Integrity information for one payload file.
    public struct FileRecord: Codable, Equatable, Sendable {
        public let sourceID: String
        /// Path below a directory source, or an empty string for a file source.
        public let relativePath: String
        public let byteCount: Int64
        public let modifiedAt: Date?
        public let sha256: String

        public init(
            sourceID: String,
            relativePath: String,
            byteCount: Int64,
            modifiedAt: Date?,
            sha256: String
        ) {
            self.sourceID = sourceID
            self.relativePath = relativePath
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
            self.sha256 = sha256
        }
    }
}

/// A verified snapshot and its directory.
public struct SaveSnapshot: Equatable, Sendable {
    public let url: URL
    public let manifest: SaveSnapshotManifest

    public init(url: URL, manifest: SaveSnapshotManifest) {
        self.url = url
        self.manifest = manifest
    }
}

/// Fail-closed validation errors from ``SaveVault``.
public enum SaveVaultError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case duplicateSourceID(String)
    case overlappingPaths(String)
    case requiredSourceMissing(String)
    case sourceTypeMismatch(String)
    case symbolicLinkNotAllowed(String)
    case unsupportedSourceItem(String)
    case snapshotAlreadyExists(String)
    case snapshotOutsideVault
    case manifestMissing
    case unsupportedSchema(Int)
    case invalidManifest(String)
    case payloadMissing(String)
    case byteCountMismatch(String)
    case checksumMismatch(String)
    case unexpectedPayload(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            "Invalid save identifier: \(value)"
        case let .duplicateSourceID(value):
            "Duplicate save source ID: \(value)"
        case let .overlappingPaths(value):
            "The save source and vault overlap: \(value)"
        case let .requiredSourceMissing(value):
            "Required save source is missing: \(value)"
        case let .sourceTypeMismatch(value):
            "Save source has the wrong type: \(value)"
        case let .symbolicLinkNotAllowed(value):
            "Symbolic links are not allowed in a save snapshot: \(value)"
        case let .unsupportedSourceItem(value):
            "Unsupported item in save source: \(value)"
        case let .snapshotAlreadyExists(value):
            "Save snapshot already exists: \(value)"
        case .snapshotOutsideVault:
            "Save snapshot is outside this vault"
        case .manifestMissing:
            "Save snapshot manifest is missing"
        case let .unsupportedSchema(version):
            "Unsupported save snapshot schema: \(version)"
        case let .invalidManifest(reason):
            "Invalid save snapshot manifest: \(reason)"
        case let .payloadMissing(path):
            "Save snapshot payload is missing: \(path)"
        case let .byteCountMismatch(path):
            "Save snapshot file size changed: \(path)"
        case let .checksumMismatch(path):
            "Save snapshot checksum changed: \(path)"
        case let .unexpectedPayload(path):
            "Save snapshot contains an unlisted file: \(path)"
        }
    }
}
