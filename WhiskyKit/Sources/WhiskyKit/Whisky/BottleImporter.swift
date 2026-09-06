//
//  BottleImporter.swift
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

public struct BottleImportResult: Equatable, Sendable {
    public let sourceURL: URL
    public let bottleURL: URL
    public let fileCount: Int
    public let byteCount: Int64

    public init(sourceURL: URL, bottleURL: URL, fileCount: Int, byteCount: Int64) {
        self.sourceURL = sourceURL
        self.bottleURL = bottleURL
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

public enum BottleImportError: LocalizedError, Equatable {
    case sourceMissing
    case sourceIsNotBottle
    case pathsOverlap
    case destinationExists
    case unreadableItem(String)
    case unsupportedItem(String)
    case sourceChanged
    case copyVerificationFailed
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The Whisky bottle no longer exists"
        case .sourceIsNotBottle:
            "The selected folder is not a Whisky bottle"
        case .pathsOverlap:
            "The OpenBottle copy cannot be stored inside its source"
        case .destinationExists:
            "The OpenBottle destination already exists"
        case let .unreadableItem(path):
            "The bottle could not be read at: \(path)"
        case let .unsupportedItem(path):
            "The bottle contains an unsupported item: \(path)"
        case .sourceChanged:
            "The Whisky bottle changed while it was being copied. Close its games and try again."
        case .copyVerificationFailed:
            "The OpenBottle copy did not match the original bottle"
        case let .insufficientSpace(required, available):
            "The bottle needs \(required) bytes but only \(available) bytes are available"
        }
    }
}

/// Copies a foreign bottle into OpenBottle without mutating or registering the source.
public enum BottleImporter {
    private struct TreeManifest: Equatable {
        let directories: [String]
        let files: [FileRecord]
        let symbolicLinks: [LinkRecord]

        var byteCount: Int64 {
            files.reduce(0) { $0 + $1.byteCount }
        }
    }

    private struct FileRecord: Equatable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    private struct LinkRecord: Equatable {
        let path: String
        let destination: String
    }

    private enum ManifestItem {
        case directory(String)
        case file(FileRecord)
        case symbolicLink(LinkRecord)
    }

    public static func copy(
        bottleAt sourceURL: URL,
        to destinationRoot: URL,
        identifier: UUID = UUID()
    ) throws -> BottleImportResult {
        let manager = FileManager.default
        let source = try validatedSource(sourceURL)
        let root = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard !SaveVault.pathsOverlap(source, root) else {
            throw BottleImportError.pathsOverlap
        }
        let name = identifier.uuidString.uppercased()
        let destination = root.appending(path: name, directoryHint: .isDirectory)
        let staging = root.appending(
            path: ".import-\(name)-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        guard !manager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw BottleImportError.destinationExists
        }

        let before = try manifest(for: source)
        try requireCapacity(for: before.byteCount, at: root)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var removeStaging = true
        defer {
            if removeStaging {
                try? manager.removeItem(at: staging)
            }
        }

        try manager.copyItem(at: source, to: staging)
        let copied = try manifest(for: staging)
        guard copied == before else {
            throw BottleImportError.copyVerificationFailed
        }
        guard try manifest(for: source) == before else {
            throw BottleImportError.sourceChanged
        }
        try manager.moveItem(at: staging, to: destination)
        removeStaging = false
        guard try manifest(for: destination) == before else {
            throw BottleImportError.copyVerificationFailed
        }
        return BottleImportResult(
            sourceURL: source,
            bottleURL: destination,
            fileCount: before.files.count,
            byteCount: before.byteCount
        )
    }

    private static func validatedSource(_ sourceURL: URL) throws -> URL {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw BottleImportError.sourceMissing
        }
        guard FileManager.default.fileExists(
            atPath: source.appending(path: "Metadata.plist").path(percentEncoded: false)
        )
        else {
            throw BottleImportError.sourceIsNotBottle
        }
        return source
    }

    private static func manifest(for root: URL) throws -> TreeManifest {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var unreadableItem: URL?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { item, _ in
                unreadableItem = item
                return false
            }
        )
        else {
            throw BottleImportError.sourceMissing
        }
        var directories: [String] = []
        var files: [FileRecord] = []
        var links: [LinkRecord] = []
        for case let item as URL in enumerator {
            switch try manifestItem(for: item, below: root, keys: keys) {
            case let .directory(path): directories.append(path)
            case let .file(record): files.append(record)
            case let .symbolicLink(record): links.append(record)
            }
        }
        if let unreadableItem {
            let path = (try? SaveVault.relativePath(of: unreadableItem, below: root))
                ?? unreadableItem.lastPathComponent
            throw BottleImportError.unreadableItem(path)
        }
        return TreeManifest(
            directories: directories.sorted(),
            files: files.sorted { $0.path < $1.path },
            symbolicLinks: links.sorted { $0.path < $1.path }
        )
    }

    private static func manifestItem(
        for item: URL,
        below root: URL,
        keys: Set<URLResourceKey>
    ) throws -> ManifestItem {
        let path = try SaveVault.relativePath(of: item, below: root)
        let values = try item.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            return try .symbolicLink(LinkRecord(
                path: path,
                destination: FileManager.default.destinationOfSymbolicLink(atPath: item.path)
            ))
        }
        if values.isDirectory == true {
            return .directory(path)
        }
        if values.isRegularFile == true {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            return try .file(FileRecord(
                path: path,
                byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                sha256: StreamingFileHash.sha256(of: item)
            ))
        }
        throw BottleImportError.unsupportedItem(path)
    }

    private static func requireCapacity(for byteCount: Int64, at root: URL) throws {
        let probe = existingAncestor(of: root)
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let required = max(byteCount + 536_870_912, byteCount * 11 / 10)
        guard available >= required else {
            throw BottleImportError.insufficientSpace(required: required, available: available)
        }
    }

    private static func existingAncestor(of suppliedURL: URL) -> URL {
        var url = suppliedURL.standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let parent = url.deletingLastPathComponent()
            guard parent != url else { return url }
            url = parent
        }
        return url
    }
}
