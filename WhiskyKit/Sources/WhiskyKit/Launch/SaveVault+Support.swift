//
//  SaveVault+Support.swift
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

import CryptoKit
import Foundation

extension SaveVault {
    func validate(sources: [SaveSource]) throws {
        var ids = Set<String>()
        var canonicalURLs: [URL] = []

        for source in sources {
            try Self.validateIdentifier(source.id)
            guard ids.insert(source.id).inserted else {
                throw SaveVaultError.duplicateSourceID(source.id)
            }

            let sourceURL = source.url.standardizedFileURL.resolvingSymlinksInPath()
            guard !canonicalURLs.contains(where: { Self.pathsOverlap($0, sourceURL) }) else {
                throw SaveVaultError.overlappingPaths(source.id)
            }
            if Self.pathsOverlap(sourceURL, rootURL) {
                throw SaveVaultError.overlappingPaths(source.id)
            }
            canonicalURLs.append(sourceURL)
        }
    }

    static func write(manifest: SaveSnapshotManifest, to snapshotURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(
            to: snapshotURL.appending(path: manifestFileName, directoryHint: .notDirectory),
            options: .atomic
        )
    }

    static func fileRecord(
        sourceID: String,
        relativePath: String,
        payloadURL: URL
    ) throws -> SaveSnapshotManifest.FileRecord {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: payloadURL.path(percentEncoded: false)
        )
        return try SaveSnapshotManifest.FileRecord(
            sourceID: sourceID,
            relativePath: relativePath,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date,
            sha256: sha256(of: payloadURL)
        )
    }

    static func fileRecordOrder(
        lhs: SaveSnapshotManifest.FileRecord,
        rhs: SaveSnapshotManifest.FileRecord
    ) -> Bool {
        if lhs.sourceID != rhs.sourceID {
            return lhs.sourceID < rhs.sourceID
        }
        return lhs.relativePath < rhs.relativePath
    }

    static func directoryRecordOrder(
        lhs: SaveSnapshotManifest.DirectoryRecord,
        rhs: SaveSnapshotManifest.DirectoryRecord
    ) -> Bool {
        if lhs.sourceID != rhs.sourceID {
            return lhs.sourceID < rhs.sourceID
        }
        return lhs.relativePath < rhs.relativePath
    }

    static func payloadPath(
        for file: SaveSnapshotManifest.FileRecord,
        sourceKind: SaveSourceKind
    ) -> String {
        switch sourceKind {
        case .file:
            "\(file.sourceID)/file"
        case .directory:
            "\(file.sourceID)/root/\(file.relativePath)"
        }
    }

    static func payloadContents(
        below root: URL
    ) throws -> (files: Set<String>, directories: Set<String>) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path(percentEncoded: false)) else {
            throw SaveVaultError.payloadMissing(payloadDirectoryName)
        }
        guard try fileType(at: root) == .typeDirectory else {
            throw SaveVaultError.unsupportedSourceItem(payloadDirectoryName)
        }
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        )
        else {
            throw SaveVaultError.payloadMissing(payloadDirectoryName)
        }

        var files = Set<String>()
        var directories = Set<String>()
        for case let url as URL in enumerator {
            let relative = try relativePath(of: url, below: root)
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                throw SaveVaultError.symbolicLinkNotAllowed(relative)
            }
            if values.isRegularFile == true {
                files.insert(relative)
            } else if values.isDirectory == true {
                directories.insert(relative)
            } else {
                throw SaveVaultError.unsupportedSourceItem(relative)
            }
        }
        if enumerationError != nil {
            throw SaveVaultError.unsupportedSourceItem(payloadDirectoryName)
        }
        return (files, directories)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileType(at url: URL) throws -> FileAttributeType? {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        return attributes[.type] as? FileAttributeType
    }

    static func relativePath(of child: URL, below root: URL) throws -> String {
        let rootPath = normalizedPath(root)
        let childPath = normalizedPath(child)
        let prefix = rootPath + "/"
        guard childPath.hasPrefix(prefix) else {
            throw SaveVaultError.invalidManifest("payload path escaped its source")
        }
        let relative = String(childPath.dropFirst(prefix.count))
        try validate(relativePath: relative, for: .directory)
        return relative
    }

    static func validate(relativePath: String, for kind: SaveSourceKind) throws {
        if kind == .file {
            guard relativePath.isEmpty else {
                throw SaveVaultError.invalidManifest("file source has a relative path")
            }
            return
        }
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\")
        else {
            throw SaveVaultError.invalidManifest("unsafe relative path")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SaveVaultError.invalidManifest("unsafe relative path")
        }
    }

    static func validateIdentifier(_ value: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw SaveVaultError.invalidIdentifier(value)
        }
    }

    static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        isDescendant(lhs, of: rhs) || isDescendant(rhs, of: lhs) || lhs == rhs
    }

    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = normalizedPath(child)
        let parentPath = normalizedPath(parent)
        let prefix = parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
