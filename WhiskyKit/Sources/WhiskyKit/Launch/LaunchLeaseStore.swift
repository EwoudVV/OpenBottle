//
//  LaunchLeaseStore.swift
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

#if canImport(Darwin)
import Darwin
#endif
import Foundation

public enum LaunchLeaseError: LocalizedError, Equatable {
    case bottleBusy
    case recoveryRequired
    case invalidLease
    case leaseOwnedByAnotherLaunch

    public var errorDescription: String? {
        switch self {
        case .bottleBusy:
            "Another game is already using this bottle"
        case .recoveryRequired:
            "This bottle has interrupted launch cleanup. Open OpenBottle to recover it before playing."
        case .invalidLease:
            "The bottle's launch lock is damaged"
        case .leaseOwnedByAnotherLaunch:
            "The bottle's launch lock belongs to another game"
        }
    }
}

/// A cross-process, per-bottle lock tied to a durable launch transaction.
public actor LaunchLeaseStore {
    public struct Lease: Codable, Equatable, Sendable {
        public static let currentSchemaVersion = 1

        public let schemaVersion: Int
        public let bottleID: String
        public let transactionID: UUID
        public let processID: Int32
        public let createdAt: Date

        public init(
            schemaVersion: Int = Lease.currentSchemaVersion,
            bottleID: String,
            transactionID: UUID,
            processID: Int32,
            createdAt: Date
        ) {
            self.schemaVersion = schemaVersion
            self.bottleID = bottleID
            self.transactionID = transactionID
            self.processID = processID
            self.createdAt = createdAt
        }
    }

    public let rootURL: URL
    private let processID: Int32

    public init(
        rootURL: URL,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.processID = processID
    }

    public func acquire(
        bottleID: String,
        transactionID: UUID,
        at date: Date = Date()
    ) throws -> Lease {
        try SaveVault.validateIdentifier(bottleID)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let lease = Lease(
            bottleID: bottleID,
            transactionID: transactionID,
            processID: processID,
            createdAt: date
        )
        let url = leaseURL(for: bottleID)
        do {
            try encoded(lease).write(to: url, options: .withoutOverwriting)
            return lease
        } catch {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw error
            }
            let existing = try readLease(at: url)
            if existing.transactionID == transactionID {
                return existing
            }
            throw Self.processIsAlive(existing.processID)
                ? LaunchLeaseError.bottleBusy
                : LaunchLeaseError.recoveryRequired
        }
    }

    public func release(bottleID: String, transactionID: UUID) throws {
        let url = leaseURL(for: bottleID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let lease = try readLease(at: url)
        guard lease.transactionID == transactionID else {
            throw LaunchLeaseError.leaseOwnedByAnotherLaunch
        }
        try FileManager.default.removeItem(at: url)
    }

    public func lease(for bottleID: String) throws -> Lease? {
        let url = leaseURL(for: bottleID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try readLease(at: url)
    }

    private func leaseURL(for bottleID: String) -> URL {
        rootURL.appending(path: bottleID).appendingPathExtension("json")
    }

    private func readLease(at url: URL) throws -> Lease {
        let lease: Lease
        do {
            lease = try JSONDecoder.openBottleLeaseDecoder.decode(
                Lease.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw LaunchLeaseError.invalidLease
        }
        guard lease.schemaVersion == Lease.currentSchemaVersion else {
            throw LaunchLeaseError.invalidLease
        }
        return lease
    }

    private func encoded(_ lease: Lease) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(lease)
    }

    private nonisolated static func processIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        #if canImport(Darwin)
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno != ESRCH
        #else
        return true
        #endif
    }
}

private extension JSONDecoder {
    static var openBottleLeaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
