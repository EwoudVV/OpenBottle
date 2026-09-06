//
//  SaveRestoreTransaction.swift
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

/// Durable phases for a save restore that may be resumed after a crash.
public enum SaveRestoreStage: String, Codable, Equatable, Sendable {
    case created
    case rollbackCaptured
    case prepared
    case applying
    case recoveryNeeded
    case cleaningUp
    case completed
    case failed

    public var isTerminal: Bool {
        self == .completed || self == .failed
    }

    fileprivate func canAdvance(to next: SaveRestoreStage) -> Bool {
        switch (self, next) {
        case (.created, .rollbackCaptured),
             (.created, .failed),
             (.rollbackCaptured, .prepared),
             (.rollbackCaptured, .failed),
             (.prepared, .applying),
             (.prepared, .failed),
             (.applying, .cleaningUp),
             (.applying, .recoveryNeeded),
             (.recoveryNeeded, .failed),
             (.cleaningUp, .completed),
             (.cleaningUp, .recoveryNeeded):
            true
        default:
            false
        }
    }
}

/// Private on-disk state needed to finish or roll back one restore.
public struct SaveRestoreRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let bottleID: String
    public let gameID: String
    public let targetSnapshotID: String
    public private(set) var rollbackSnapshotID: String?
    public private(set) var stage: SaveRestoreStage
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var failureCode: String?

    public init(
        schemaVersion: Int = SaveRestoreRecord.currentSchemaVersion,
        id: UUID,
        bottleID: String,
        gameID: String,
        targetSnapshotID: String,
        rollbackSnapshotID: String? = nil,
        stage: SaveRestoreStage,
        createdAt: Date,
        updatedAt: Date,
        failureCode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.bottleID = bottleID
        self.gameID = gameID
        self.targetSnapshotID = targetSnapshotID
        self.rollbackSnapshotID = rollbackSnapshotID
        self.stage = stage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.failureCode = failureCode
    }

    fileprivate mutating func advance(
        to next: SaveRestoreStage,
        rollbackSnapshotID: String?,
        failureCode: String?,
        at date: Date
    ) {
        stage = next
        updatedAt = date
        if let rollbackSnapshotID {
            self.rollbackSnapshotID = rollbackSnapshotID
        }
        if let failureCode {
            self.failureCode = failureCode
        }
    }
}

public enum SaveRestoreJournalError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case recordAlreadyExists(UUID)
    case recordMissing(UUID)
    case invalidRecord(UUID)
    case unsupportedSchema(Int)
    case invalidTransition(from: SaveRestoreStage, nextStage: SaveRestoreStage)
    case rollbackSnapshotRequired

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            "Invalid save restore identifier: \(value)"
        case let .recordAlreadyExists(identifier):
            "Save restore already exists: \(identifier)"
        case let .recordMissing(identifier):
            "Save restore does not exist: \(identifier)"
        case let .invalidRecord(identifier):
            "Save restore record is invalid: \(identifier)"
        case let .unsupportedSchema(version):
            "Unsupported save restore schema: \(version)"
        case let .invalidTransition(previous, next):
            "Invalid save restore transition from \(previous.rawValue) to \(next.rawValue)"
        case .rollbackSnapshotRequired:
            "A rollback snapshot is required before restoring saves"
        }
    }
}

/// Atomic journal for restoring a save without losing the state it replaces.
public actor SaveRestoreJournal {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func begin(
        bottleID: String,
        gameID: String,
        targetSnapshotID: String,
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) throws -> SaveRestoreRecord {
        try [bottleID, gameID, targetSnapshotID].forEach(Self.validateIdentifier)
        let url = recordURL(for: identifier)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw SaveRestoreJournalError.recordAlreadyExists(identifier)
        }
        let record = SaveRestoreRecord(
            id: identifier,
            bottleID: bottleID,
            gameID: gameID,
            targetSnapshotID: targetSnapshotID,
            stage: .created,
            createdAt: date,
            updatedAt: date
        )
        try write(record)
        return record
    }

    @discardableResult
    public func advance(
        _ identifier: UUID,
        to next: SaveRestoreStage,
        rollbackSnapshotID: String? = nil,
        at date: Date = Date()
    ) throws -> SaveRestoreRecord {
        var record = try load(identifier)
        guard record.stage.canAdvance(to: next) else {
            throw SaveRestoreJournalError.invalidTransition(from: record.stage, nextStage: next)
        }
        if next == .rollbackCaptured, rollbackSnapshotID == nil {
            throw SaveRestoreJournalError.rollbackSnapshotRequired
        }
        if rollbackSnapshotID != nil, next != .rollbackCaptured {
            throw SaveRestoreJournalError.invalidTransition(from: record.stage, nextStage: next)
        }
        if let rollbackSnapshotID {
            try Self.validateIdentifier(rollbackSnapshotID)
        }
        record.advance(
            to: next,
            rollbackSnapshotID: rollbackSnapshotID,
            failureCode: nil,
            at: date
        )
        try write(record)
        return record
    }

    /// A pre-apply failure is terminal. Once live files may have moved, recovery is required.
    @discardableResult
    public func fail(
        _ identifier: UUID,
        code: String,
        at date: Date = Date()
    ) throws -> SaveRestoreRecord {
        try Self.validateIdentifier(code)
        var record = try load(identifier)
        let next: SaveRestoreStage
        switch record.stage {
        case .created, .rollbackCaptured, .prepared:
            next = .failed
        case .applying, .cleaningUp:
            next = .recoveryNeeded
        case .recoveryNeeded:
            next = .recoveryNeeded
        case .completed, .failed:
            throw SaveRestoreJournalError.invalidTransition(from: record.stage, nextStage: .failed)
        }
        record.advance(to: next, rollbackSnapshotID: nil, failureCode: code, at: date)
        try write(record)
        return record
    }

    /// Marks a verified rollback complete while retaining the original failure code.
    @discardableResult
    public func finishRecovery(
        _ identifier: UUID,
        at date: Date = Date()
    ) throws -> SaveRestoreRecord {
        var record = try load(identifier)
        guard record.stage.canAdvance(to: .failed) else {
            throw SaveRestoreJournalError.invalidTransition(from: record.stage, nextStage: .failed)
        }
        record.advance(to: .failed, rollbackSnapshotID: nil, failureCode: nil, at: date)
        try write(record)
        return record
    }

    public func record(for identifier: UUID) throws -> SaveRestoreRecord {
        try load(identifier)
    }

    public func unfinished() throws -> [SaveRestoreRecord] {
        guard FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                guard let identifier = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    throw SaveRestoreJournalError.invalidIdentifier(url.lastPathComponent)
                }
                return try load(identifier)
            }
            .filter { !$0.stage.isTerminal }
            .sorted(by: Self.recordOrder)
    }

    private func load(_ identifier: UUID) throws -> SaveRestoreRecord {
        let url = recordURL(for: identifier)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw SaveRestoreJournalError.recordMissing(identifier)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: SaveRestoreRecord
        do {
            record = try decoder.decode(SaveRestoreRecord.self, from: Data(contentsOf: url))
        } catch {
            throw SaveRestoreJournalError.invalidRecord(identifier)
        }
        guard record.id == identifier else {
            throw SaveRestoreJournalError.invalidRecord(identifier)
        }
        guard record.schemaVersion == SaveRestoreRecord.currentSchemaVersion else {
            throw SaveRestoreJournalError.unsupportedSchema(record.schemaVersion)
        }
        let requiresRollback: Set<SaveRestoreStage> = [
            .rollbackCaptured, .prepared, .applying, .recoveryNeeded, .cleaningUp, .completed
        ]
        if requiresRollback.contains(record.stage), record.rollbackSnapshotID == nil {
            throw SaveRestoreJournalError.invalidRecord(identifier)
        }
        try Self.validate(record)
        return record
    }

    private func write(_ record: SaveRestoreRecord) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: recordURL(for: record.id), options: .atomic)
    }

    private func recordURL(for identifier: UUID) -> URL {
        rootURL
            .appending(path: identifier.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private static func validate(_ record: SaveRestoreRecord) throws {
        try [record.bottleID, record.gameID, record.targetSnapshotID]
            .forEach(validateIdentifier)
        if let rollbackSnapshotID = record.rollbackSnapshotID {
            try validateIdentifier(rollbackSnapshotID)
        }
        if let failureCode = record.failureCode {
            try validateIdentifier(failureCode)
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        do {
            try SaveVault.validateIdentifier(value)
        } catch {
            throw SaveRestoreJournalError.invalidIdentifier(value)
        }
    }

    private static func recordOrder(_ lhs: SaveRestoreRecord, _ rhs: SaveRestoreRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
