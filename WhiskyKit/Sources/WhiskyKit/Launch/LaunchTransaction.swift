//
//  LaunchTransaction.swift
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

/// Durable stages shared by every future game launch path.
public enum LaunchTransactionStage: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case preflightPassed
    case saveCaptured
    case prepared
    case launchRequested
    case monitoring
    case recoveryNeeded
    case cleaningUp
    case completed
    case failed

    /// Whether no further transition is valid.
    public var isTerminal: Bool {
        self == .completed || self == .failed
    }

    fileprivate func canAdvance(to next: LaunchTransactionStage) -> Bool {
        switch (self, next) {
        case (.created, .preflightPassed),
             (.created, .failed),
             (.preflightPassed, .saveCaptured),
             (.preflightPassed, .prepared),
             (.preflightPassed, .failed),
             (.saveCaptured, .prepared),
             (.saveCaptured, .failed),
             (.prepared, .launchRequested),
             (.prepared, .recoveryNeeded),
             (.launchRequested, .monitoring),
             (.launchRequested, .cleaningUp),
             (.launchRequested, .recoveryNeeded),
             (.monitoring, .cleaningUp),
             (.monitoring, .recoveryNeeded),
             (.recoveryNeeded, .cleaningUp),
             (.cleaningUp, .recoveryNeeded),
             (.cleaningUp, .completed),
             (.cleaningUp, .failed):
            true
        default:
            false
        }
    }
}

/// On-disk record of one launch transaction.
///
/// The record stores stable IDs rather than executable or save paths, so it is
/// safe to include in a scrubbed diagnostic report later.
public struct LaunchTransactionRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let bottleID: String
    public let gameID: String
    public let runtimeSlotID: String?
    public private(set) var stage: LaunchTransactionStage
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var saveSnapshotID: String?
    public private(set) var postLaunchSaveSnapshotID: String?
    public private(set) var failureCode: String?

    public init(
        schemaVersion: Int = LaunchTransactionRecord.currentSchemaVersion,
        id: UUID,
        bottleID: String,
        gameID: String,
        runtimeSlotID: String? = nil,
        stage: LaunchTransactionStage,
        createdAt: Date,
        updatedAt: Date,
        saveSnapshotID: String? = nil,
        postLaunchSaveSnapshotID: String? = nil,
        failureCode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.bottleID = bottleID
        self.gameID = gameID
        self.runtimeSlotID = runtimeSlotID
        self.stage = stage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.saveSnapshotID = saveSnapshotID
        self.postLaunchSaveSnapshotID = postLaunchSaveSnapshotID
        if let failureCode {
            self.failureCode = failureCode
        }
    }

    fileprivate mutating func advance(
        to next: LaunchTransactionStage,
        saveSnapshotID: String?,
        postLaunchSaveSnapshotID: String?,
        failureCode: String?,
        at date: Date
    ) {
        stage = next
        updatedAt = date
        if let saveSnapshotID {
            self.saveSnapshotID = saveSnapshotID
        }
        if let postLaunchSaveSnapshotID {
            self.postLaunchSaveSnapshotID = postLaunchSaveSnapshotID
        }
        if let failureCode {
            self.failureCode = failureCode
        }
    }
}

/// Validation and persistence failures from ``LaunchTransactionJournal``.
public enum LaunchTransactionError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case recordAlreadyExists(UUID)
    case recordMissing(UUID)
    case invalidRecord(UUID)
    case unsupportedSchema(Int)
    case invalidTransition(from: LaunchTransactionStage, nextStage: LaunchTransactionStage)
    case saveSnapshotRequired

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            "Invalid launch transaction identifier: \(value)"
        case let .recordAlreadyExists(id):
            "Launch transaction already exists: \(id)"
        case let .recordMissing(id):
            "Launch transaction does not exist: \(id)"
        case let .invalidRecord(id):
            "Launch transaction record is invalid: \(id)"
        case let .unsupportedSchema(version):
            "Unsupported launch transaction schema: \(version)"
        case let .invalidTransition(previousStage, nextStage):
            "Invalid launch transition from \(previousStage.rawValue) to \(nextStage.rawValue)"
        case .saveSnapshotRequired:
            "A save snapshot ID is required for the save-captured stage"
        }
    }
}

/// Atomic journal for launches that may outlive the app process.
///
/// An unfinished record is recovery work, not history. On the next app launch,
/// callers can inspect ``unfinished()`` and finish cleanup before allowing the
/// same game or bottle to run again.
public actor LaunchTransactionJournal {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// Creates a transaction in the first durable stage.
    public func begin(
        bottleID: String,
        gameID: String,
        runtimeSlotID: String? = nil,
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) throws -> LaunchTransactionRecord {
        try Self.validateIdentifier(bottleID)
        try Self.validateIdentifier(gameID)
        if let runtimeSlotID {
            try Self.validateIdentifier(runtimeSlotID)
        }
        let url = recordURL(for: identifier)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw LaunchTransactionError.recordAlreadyExists(identifier)
        }

        let record = LaunchTransactionRecord(
            id: identifier,
            bottleID: bottleID,
            gameID: gameID,
            runtimeSlotID: runtimeSlotID,
            stage: .created,
            createdAt: date,
            updatedAt: date
        )
        try write(record)
        return record
    }

    /// Advances a transaction by one allowed edge and writes it atomically.
    @discardableResult
    public func advance(
        _ identifier: UUID,
        to next: LaunchTransactionStage,
        saveSnapshotID: String? = nil,
        postLaunchSaveSnapshotID: String? = nil,
        at date: Date = Date()
    ) throws -> LaunchTransactionRecord {
        var record = try load(identifier)
        guard record.stage.canAdvance(to: next) else {
            throw LaunchTransactionError.invalidTransition(from: record.stage, nextStage: next)
        }
        if next == .saveCaptured, saveSnapshotID == nil {
            throw LaunchTransactionError.saveSnapshotRequired
        }
        if let saveSnapshotID {
            try Self.validateIdentifier(saveSnapshotID)
        }
        if let postLaunchSaveSnapshotID {
            try Self.validateIdentifier(postLaunchSaveSnapshotID)
        }

        record.advance(
            to: next,
            saveSnapshotID: saveSnapshotID,
            postLaunchSaveSnapshotID: postLaunchSaveSnapshotID,
            failureCode: nil,
            at: date
        )
        try write(record)
        return record
    }

    /// Records a scrubbed failure code without hiding required cleanup.
    ///
    /// A failure before preparation is terminal because no temporary runtime
    /// state exists. Once preparation begins, the record remains recoverable
    /// until cleanup advances it from `recoveryNeeded` to `cleaningUp` and then
    /// `failed`.
    @discardableResult
    public func fail(
        _ identifier: UUID,
        code: String,
        at date: Date = Date()
    ) throws -> LaunchTransactionRecord {
        try Self.validateIdentifier(code)
        var record = try load(identifier)
        let next: LaunchTransactionStage
        switch record.stage {
        case .created, .preflightPassed, .saveCaptured:
            next = .failed
        case .prepared, .launchRequested, .monitoring, .cleaningUp:
            next = .recoveryNeeded
        case .recoveryNeeded:
            next = .recoveryNeeded
        case .completed, .failed:
            throw LaunchTransactionError.invalidTransition(from: record.stage, nextStage: .failed)
        }
        record.advance(
            to: next,
            saveSnapshotID: nil,
            postLaunchSaveSnapshotID: nil,
            failureCode: code,
            at: date
        )
        try write(record)
        return record
    }

    /// Reads one record and validates its identity and schema.
    public func record(for identifier: UUID) throws -> LaunchTransactionRecord {
        try load(identifier)
    }

    /// Returns every transaction that still needs monitoring or cleanup.
    public func unfinished() throws -> [LaunchTransactionRecord] {
        try records().filter { !$0.stage.isTerminal }
    }

    /// Returns the path-free launch history for local reports.
    public func records() throws -> [LaunchTransactionRecord] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path(percentEncoded: false)) else {
            return []
        }
        let urls = try manager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                guard let identifier = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    throw LaunchTransactionError.invalidIdentifier(url.lastPathComponent)
                }
                return try load(identifier)
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    // MARK: - Persistence

    private func load(_ identifier: UUID) throws -> LaunchTransactionRecord {
        let url = recordURL(for: identifier)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw LaunchTransactionError.recordMissing(identifier)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: LaunchTransactionRecord
        do {
            record = try decoder.decode(
                LaunchTransactionRecord.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw LaunchTransactionError.invalidRecord(identifier)
        }
        guard record.id == identifier else {
            throw LaunchTransactionError.invalidRecord(identifier)
        }
        guard record.schemaVersion == LaunchTransactionRecord.currentSchemaVersion else {
            throw LaunchTransactionError.unsupportedSchema(record.schemaVersion)
        }
        try Self.validateIdentifier(record.bottleID)
        try Self.validateIdentifier(record.gameID)
        if let runtimeSlotID = record.runtimeSlotID {
            try Self.validateIdentifier(runtimeSlotID)
        }
        if let saveSnapshotID = record.saveSnapshotID {
            try Self.validateIdentifier(saveSnapshotID)
        }
        if let postLaunchSaveSnapshotID = record.postLaunchSaveSnapshotID {
            try Self.validateIdentifier(postLaunchSaveSnapshotID)
        }
        if let failureCode = record.failureCode {
            try Self.validateIdentifier(failureCode)
        }
        return record
    }

    private func write(_ record: LaunchTransactionRecord) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: recordURL(for: record.id), options: .atomic)
    }

    private func recordURL(for identifier: UUID) -> URL {
        rootURL
            .appending(path: identifier.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private static func validateIdentifier(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw LaunchTransactionError.invalidIdentifier(value)
        }
    }
}
