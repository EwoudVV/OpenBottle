//
//  SaveRestore.swift
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

/// A completed restore and the automatic point containing the state it replaced.
public struct SaveRestoreResult: Equatable, Sendable {
    public let restoredSnapshot: SaveSnapshot
    public let rollbackSnapshot: SaveSnapshot
    public let record: SaveRestoreRecord

    public init(
        restoredSnapshot: SaveSnapshot,
        rollbackSnapshot: SaveSnapshot,
        record: SaveRestoreRecord
    ) {
        self.restoredSnapshot = restoredSnapshot
        self.rollbackSnapshot = rollbackSnapshot
        self.record = record
    }
}

public enum SaveRestoreError: LocalizedError, Equatable {
    case snapshotScopeMismatch
    case sourcePlanMismatch(String)
    case liveStateMismatch(String)
    case targetSymbolicLink(String)
    case rollbackSnapshotMissing
    case recoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .snapshotScopeMismatch:
            "The save snapshot belongs to a different game or bottle"
        case let .sourcePlanMismatch(sourceID):
            "The current save plan does not match this snapshot: \(sourceID)"
        case let .liveStateMismatch(sourceID):
            "The restored save did not match its verified snapshot: \(sourceID)"
        case let .targetSymbolicLink(sourceID):
            "A save restore target is a symbolic link: \(sourceID)"
        case .rollbackSnapshotMissing:
            "The rollback snapshot for this restore is missing"
        case let .recoveryFailed(code):
            "The original save could not be recovered: \(code)"
        }
    }
}
