//
//  SaveSourcePlanStore.swift
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

public enum SaveSourcePlanError: LocalizedError, Equatable {
    case invalidRecord
    case duplicateSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "The saved game-location plan is damaged"
        case let .duplicateSource(identifier):
            "The saved game-location plan repeats \(identifier)"
        }
    }
}

public struct SaveSourcePlanRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public enum Location: Codable, Equatable, Sendable {
        case bottleRelative(String)
        case absolute(String)
    }

    public struct Source: Codable, Equatable, Sendable {
        public let id: String
        public let location: Location
        public let kind: SaveSourceKind
        public let required: Bool

        public init(id: String, location: Location, kind: SaveSourceKind, required: Bool) {
            self.id = id
            self.location = location
            self.kind = kind
            self.required = required
        }
    }

    public let schemaVersion: Int
    public let bottleID: String
    public let gameID: String
    public let sources: [Source]
    public let updatedAt: Date

    public init(
        schemaVersion: Int = SaveSourcePlanRecord.currentSchemaVersion,
        bottleID: String,
        gameID: String,
        sources: [Source],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.bottleID = bottleID
        self.gameID = gameID
        self.sources = sources
        self.updatedAt = updatedAt
    }
}

/// Private path mapping for opaque save snapshot source IDs.
public struct SaveSourcePlanStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    @discardableResult
    public func save(
        sources: [SaveSource],
        bottleURL: URL,
        bottleID: String,
        gameID: String,
        at date: Date = Date()
    ) throws -> SaveSourcePlanRecord {
        try [bottleID, gameID].forEach(SaveVault.validateIdentifier)
        var seen = Set<String>()
        let records = try sources.sorted(by: { $0.id < $1.id }).map { source in
            try SaveVault.validateIdentifier(source.id)
            guard seen.insert(source.id).inserted else {
                throw SaveSourcePlanError.duplicateSource(source.id)
            }
            return SaveSourcePlanRecord.Source(
                id: source.id,
                location: location(for: source.url, bottleURL: bottleURL),
                kind: source.kind,
                required: source.required
            )
        }
        let record = SaveSourcePlanRecord(
            bottleID: bottleID,
            gameID: gameID,
            sources: records,
            updatedAt: date
        )
        let url = recordURL(bottleID: bottleID, gameID: gameID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: url, options: .atomic)
        return record
    }

    public func load(
        bottleURL: URL,
        bottleID: String,
        gameID: String
    ) throws -> [SaveSource] {
        let url = recordURL(bottleID: bottleID, gameID: gameID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: SaveSourcePlanRecord
        do {
            record = try decoder.decode(SaveSourcePlanRecord.self, from: Data(contentsOf: url))
        } catch {
            throw SaveSourcePlanError.invalidRecord
        }
        try validate(record, bottleID: bottleID, gameID: gameID)
        return try record.sources.map { source in
            try SaveSource(
                id: source.id,
                url: self.url(for: source.location, bottleURL: bottleURL),
                kind: source.kind,
                required: source.required
            )
        }
    }

    private func location(for url: URL, bottleURL: URL) -> SaveSourcePlanRecord.Location {
        if let relative = try? SaveVault.relativePath(of: url, below: bottleURL) {
            return .bottleRelative(relative)
        }
        return .absolute(url.standardizedFileURL.path(percentEncoded: false))
    }

    private func url(
        for location: SaveSourcePlanRecord.Location,
        bottleURL: URL
    ) throws -> URL {
        switch location {
        case let .bottleRelative(path):
            guard Self.isSafeRelativePath(path) else {
                throw SaveSourcePlanError.invalidRecord
            }
            return bottleURL.appending(path: path)
        case let .absolute(path):
            guard path.hasPrefix("/") else {
                throw SaveSourcePlanError.invalidRecord
            }
            return URL(fileURLWithPath: path)
        }
    }

    private func validate(
        _ record: SaveSourcePlanRecord,
        bottleID: String,
        gameID: String
    ) throws {
        guard record.schemaVersion == SaveSourcePlanRecord.currentSchemaVersion,
              record.bottleID == bottleID,
              record.gameID == gameID,
              Set(record.sources.map(\.id)).count == record.sources.count
        else {
            throw SaveSourcePlanError.invalidRecord
        }
        try record.sources.forEach { try SaveVault.validateIdentifier($0.id) }
    }

    private func recordURL(bottleID: String, gameID: String) -> URL {
        rootURL
            .appending(path: bottleID, directoryHint: .isDirectory)
            .appending(path: gameID)
            .appendingPathExtension("json")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
