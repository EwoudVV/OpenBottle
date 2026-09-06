//
//  RuntimeResolver.swift
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

public struct RuntimeSelection: Equatable, Sendable {
    public let slotID: String?
    public let libraryURL: URL
    public let manifest: RuntimeSlotManifest?
    public let reason: String

    public init(
        slotID: String?,
        libraryURL: URL,
        manifest: RuntimeSlotManifest?,
        reason: String
    ) {
        self.slotID = slotID
        self.libraryURL = libraryURL
        self.manifest = manifest
        self.reason = reason
    }
}

public struct RuntimePinRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let bottleID: String
    public let gameID: String
    public let slotID: String
    public let updatedAt: Date

    public init(
        schemaVersion: Int = RuntimePinRecord.currentSchemaVersion,
        bottleID: String,
        gameID: String,
        slotID: String,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.bottleID = bottleID
        self.gameID = gameID
        self.slotID = slotID
        self.updatedAt = updatedAt
    }
}

public enum RuntimePinError: LocalizedError, Equatable {
    case invalidRecord

    public var errorDescription: String? {
        "The game's runtime pin is damaged"
    }
}

public struct RuntimePinStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func slotID(bottleID: String, gameID: String) throws -> String? {
        let url = recordURL(bottleID: bottleID, gameID: gameID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: RuntimePinRecord
        do {
            record = try decoder.decode(RuntimePinRecord.self, from: Data(contentsOf: url))
        } catch {
            throw RuntimePinError.invalidRecord
        }
        guard record.schemaVersion == RuntimePinRecord.currentSchemaVersion,
              record.bottleID == bottleID,
              record.gameID == gameID
        else {
            throw RuntimePinError.invalidRecord
        }
        return record.slotID
    }

    public func pin(
        slotID: String,
        bottleID: String,
        gameID: String,
        at date: Date = Date()
    ) throws {
        try [slotID, bottleID, gameID].forEach(SaveVault.validateIdentifier)
        let record = RuntimePinRecord(
            bottleID: bottleID,
            gameID: gameID,
            slotID: slotID,
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
    }

    private func recordURL(bottleID: String, gameID: String) -> URL {
        rootURL
            .appending(path: bottleID, directoryHint: .isDirectory)
            .appending(path: gameID)
            .appendingPathExtension("json")
    }
}

/// Selects a verified per-game pin, then Stable, then Preview, then the legacy runtime.
public struct RuntimeResolver: Sendable {
    public let manager: RuntimeSlotManager
    public let pins: RuntimePinStore
    public let legacyLibraryURL: URL

    public init(
        manager: RuntimeSlotManager,
        pins: RuntimePinStore,
        legacyLibraryURL: URL
    ) {
        self.manager = manager
        self.pins = pins
        self.legacyLibraryURL = legacyLibraryURL
    }

    public static func live() -> RuntimeResolver {
        let manager = RuntimeSlotManager.live()
        return RuntimeResolver(
            manager: manager,
            pins: RuntimePinStore(rootURL: manager.rootURL.appending(path: "Pins")),
            legacyLibraryURL: WhiskyWineInstaller.legacyLibraryFolder
        )
    }

    public func resolve(bottleID: String, gameID: String) throws -> RuntimeSelection {
        if let pinnedID = try pins.slotID(bottleID: bottleID, gameID: gameID) {
            let slot = try manager.slot(id: pinnedID)
            try manager.verify(slot)
            return RuntimeSelection(
                slotID: slot.id,
                libraryURL: slot.libraryURL,
                manifest: slot.manifest,
                reason: "last successful launch"
            )
        }
        if let slot = try manager.defaultSlot() {
            try manager.verify(slot)
            return RuntimeSelection(
                slotID: slot.id,
                libraryURL: slot.libraryURL,
                manifest: slot.manifest,
                reason: slot.manifest.channel.rawValue
            )
        }
        return RuntimeSelection(
            slotID: nil,
            libraryURL: legacyLibraryURL,
            manifest: nil,
            reason: "legacy runtime"
        )
    }

    public func resolve(slotID: String) throws -> RuntimeSelection {
        let slot = try manager.slot(id: slotID)
        try manager.verify(slot)
        return RuntimeSelection(
            slotID: slot.id,
            libraryURL: slot.libraryURL,
            manifest: slot.manifest,
            reason: "interrupted launch"
        )
    }

    public func recordSuccess(
        _ selection: RuntimeSelection,
        bottleID: String,
        gameID: String
    ) throws {
        guard let slotID = selection.slotID else { return }
        try pins.pin(slotID: slotID, bottleID: bottleID, gameID: gameID)
    }
}
