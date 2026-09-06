//
//  GameSavePolicy.swift
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

/// Whether OpenBottle lets a store exchange a game's saves with the network.
public enum GameSavePolicy: String, Codable, CaseIterable, Equatable, Sendable {
    /// Start stores offline and keep OpenBottle's verified local restore points authoritative.
    case localOnly
    /// Allow the store's cloud feature while still taking local restore points around launches.
    case cloudAllowed
}

public struct GameSavePolicyRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let bottleID: String
    public let gameID: String
    public let policy: GameSavePolicy
    public let updatedAt: Date

    public init(
        schemaVersion: Int = GameSavePolicyRecord.currentSchemaVersion,
        bottleID: String,
        gameID: String,
        policy: GameSavePolicy,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.bottleID = bottleID
        self.gameID = gameID
        self.policy = policy
        self.updatedAt = updatedAt
    }
}

public enum GameSavePolicyError: LocalizedError, Equatable {
    case invalidRecord

    public var errorDescription: String? {
        "The saved local/cloud choice is damaged"
    }
}

/// One atomic policy file per bottle and game, shared by the app and CLI.
public actor GameSavePolicyStore {
    public static let defaultPolicy = GameSavePolicy.localOnly

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public static func live() -> GameSavePolicyStore {
        GameSavePolicyStore(
            rootURL: WhiskyWineInstaller.applicationFolder.appending(path: "Save Policies")
        )
    }

    public func policy(bottleID: String, gameID: String) throws -> GameSavePolicy {
        guard let record = try record(bottleID: bottleID, gameID: gameID) else {
            return Self.defaultPolicy
        }
        return record.policy
    }

    @discardableResult
    public func setPolicy(
        _ policy: GameSavePolicy,
        bottleID: String,
        gameID: String,
        at date: Date = Date()
    ) throws -> GameSavePolicyRecord {
        try [bottleID, gameID].forEach(SaveVault.validateIdentifier)
        let record = GameSavePolicyRecord(
            bottleID: bottleID,
            gameID: gameID,
            policy: policy,
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

    public func record(
        bottleID: String,
        gameID: String
    ) throws -> GameSavePolicyRecord? {
        try [bottleID, gameID].forEach(SaveVault.validateIdentifier)
        let url = recordURL(bottleID: bottleID, gameID: gameID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: GameSavePolicyRecord
        do {
            record = try decoder.decode(GameSavePolicyRecord.self, from: Data(contentsOf: url))
        } catch {
            throw GameSavePolicyError.invalidRecord
        }
        guard record.schemaVersion == GameSavePolicyRecord.currentSchemaVersion,
              record.bottleID == bottleID,
              record.gameID == gameID
        else {
            throw GameSavePolicyError.invalidRecord
        }
        return record
    }

    private func recordURL(bottleID: String, gameID: String) -> URL {
        rootURL
            .appending(path: bottleID, directoryHint: .isDirectory)
            .appending(path: gameID)
            .appendingPathExtension("json")
    }
}

public enum SteamSavePolicyIdentity {
    public static func gameID(appID: Int) -> String {
        "steam-\(appID)"
    }
}
