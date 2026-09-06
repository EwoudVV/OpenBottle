//
//  SaveVault+Inventory.swift
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

/// A vault scan keeps corrupt entries visible without offering them for restore.
public struct SaveSnapshotInventory: Equatable, Sendable {
    public let verified: [SaveSnapshot]
    public let invalidSnapshotIDs: [String]

    public init(verified: [SaveSnapshot], invalidSnapshotIDs: [String]) {
        self.verified = verified
        self.invalidSnapshotIDs = invalidSnapshotIDs
    }
}

/// What one retention pass changed.
public struct SaveRetentionResult: Equatable, Sendable {
    public let keptSnapshotIDs: [String]
    public let removedSnapshotIDs: [String]

    public init(keptSnapshotIDs: [String], removedSnapshotIDs: [String]) {
        self.keptSnapshotIDs = keptSnapshotIDs
        self.removedSnapshotIDs = removedSnapshotIDs
    }
}

public enum SaveVaultManagementError: LocalizedError, Equatable {
    case invalidRetentionLimit(Int)
    case invalidSnapshotsPresent([String])

    public var errorDescription: String? {
        switch self {
        case let .invalidRetentionLimit(limit):
            "Save retention must keep at least one snapshot, not \(limit)"
        case let .invalidSnapshotsPresent(identifiers):
            "Invalid save snapshots need attention before retention: \(identifiers.joined(separator: ", "))"
        }
    }
}

extension SaveVault {
    public static let defaultMaximumSnapshots = 10

    /// Finds every verified restore point for one installed game, newest first.
    public func inventory(
        bottleID: String,
        gameID: String
    ) throws -> SaveSnapshotInventory {
        try [bottleID, gameID].forEach(Self.validateIdentifier)
        let gameURL = gameDirectoryURL(bottleID: bottleID, gameID: gameID)
        guard FileManager.default.fileExists(atPath: gameURL.path(percentEncoded: false)) else {
            return SaveSnapshotInventory(verified: [], invalidSnapshotIDs: [])
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: gameURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var verified: [SaveSnapshot] = []
        var invalid: [String] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                try verified.append(verify(snapshotAt: child))
            } catch {
                invalid.append(child.lastPathComponent)
            }
        }
        verified.sort(by: Self.snapshotOrder)
        return SaveSnapshotInventory(verified: verified, invalidSnapshotIDs: invalid)
    }

    /// Deletes only old verified snapshots and refuses to act around corruption.
    @discardableResult
    public func enforceRetention(
        bottleID: String,
        gameID: String,
        maximumSnapshots: Int,
        protectedSnapshotIDs: Set<String> = []
    ) throws -> SaveRetentionResult {
        guard maximumSnapshots >= 1 else {
            throw SaveVaultManagementError.invalidRetentionLimit(maximumSnapshots)
        }
        try protectedSnapshotIDs.forEach(Self.validateIdentifier)
        let inventory = try inventory(bottleID: bottleID, gameID: gameID)
        guard inventory.invalidSnapshotIDs.isEmpty else {
            throw SaveVaultManagementError.invalidSnapshotsPresent(inventory.invalidSnapshotIDs)
        }

        let newest = inventory.verified.prefix(maximumSnapshots).map(\.manifest.id)
        let kept = Set(newest).union(protectedSnapshotIDs)
        let removable = inventory.verified.reversed().filter { !kept.contains($0.manifest.id) }
        var removed: [String] = []
        for snapshot in removable {
            _ = try verify(snapshotAt: snapshot.url)
            try FileManager.default.removeItem(at: snapshot.url)
            removed.append(snapshot.manifest.id)
        }
        return SaveRetentionResult(
            keptSnapshotIDs: inventory.verified
                .map(\.manifest.id)
                .filter(kept.contains),
            removedSnapshotIDs: removed
        )
    }

    public func snapshotURL(
        bottleID: String,
        gameID: String,
        snapshotID: String
    ) throws -> URL {
        try [bottleID, gameID, snapshotID].forEach(Self.validateIdentifier)
        return gameDirectoryURL(bottleID: bottleID, gameID: gameID)
            .appending(path: snapshotID, directoryHint: .isDirectory)
    }

    func gameDirectoryURL(bottleID: String, gameID: String) -> URL {
        rootURL
            .appending(path: bottleID, directoryHint: .isDirectory)
            .appending(path: gameID, directoryHint: .isDirectory)
    }

    private static func snapshotOrder(_ lhs: SaveSnapshot, _ rhs: SaveSnapshot) -> Bool {
        if lhs.manifest.createdAt != rhs.manifest.createdAt {
            return lhs.manifest.createdAt > rhs.manifest.createdAt
        }
        return lhs.manifest.id > rhs.manifest.id
    }
}
