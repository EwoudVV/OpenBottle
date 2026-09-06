//
//  RuntimeSlot.swift
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

public enum RuntimeChannel: String, Codable, CaseIterable, Equatable, Sendable {
    case stable
    case preview
    case imported
}

public struct RuntimeComponentManifest: Codable, Equatable, Sendable {
    public let name: String
    public let version: String?
    public let license: String
    public let sourceURL: URL
    public let representativePath: String?
    public let sha256: String?

    public init(
        name: String,
        version: String?,
        license: String,
        sourceURL: URL,
        representativePath: String?,
        sha256: String?
    ) {
        self.name = name
        self.version = version
        self.license = license
        self.sourceURL = sourceURL
        self.representativePath = representativePath
        self.sha256 = sha256
    }
}

public struct RuntimeSlotManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let channel: RuntimeChannel
    public let runtimeVersion: String
    public let createdAt: Date
    public let sourceURL: URL?
    public let archiveSHA256: String
    public let components: [RuntimeComponentManifest]
    public let capabilities: Set<String>

    public init(
        schemaVersion: Int = RuntimeSlotManifest.currentSchemaVersion,
        id: String,
        channel: RuntimeChannel,
        runtimeVersion: String,
        createdAt: Date,
        sourceURL: URL?,
        archiveSHA256: String,
        components: [RuntimeComponentManifest],
        capabilities: Set<String>
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.channel = channel
        self.runtimeVersion = runtimeVersion
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.archiveSHA256 = archiveSHA256
        self.components = components
        self.capabilities = capabilities
    }
}

public struct RuntimeSlot: Equatable, Sendable, Identifiable {
    public let url: URL
    public let manifest: RuntimeSlotManifest

    public var id: String { manifest.id }
    public var libraryURL: URL { url.appending(path: "Libraries") }

    public init(url: URL, manifest: RuntimeSlotManifest) {
        self.url = url
        self.manifest = manifest
    }
}

struct RuntimeSlotIndex: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var stableSlotID: String?
    var previewSlotID: String?

    init(
        schemaVersion: Int = RuntimeSlotIndex.currentSchemaVersion,
        stableSlotID: String? = nil,
        previewSlotID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.stableSlotID = stableSlotID
        self.previewSlotID = previewSlotID
    }
}

public enum RuntimeSlotError: LocalizedError, Equatable {
    case archiveMissing
    case archiveUnreadable
    case extractedRuntimeMissing
    case manifestMissing
    case invalidManifest
    case unsupportedManifest(Int)
    case componentChanged(String)
    case slotMissing(String)

    public var errorDescription: String? {
        switch self {
        case .archiveMissing:
            "The runtime archive no longer exists"
        case .archiveUnreadable:
            "The runtime archive could not be hashed"
        case .extractedRuntimeMissing:
            "The runtime archive does not contain a usable Libraries folder"
        case .manifestMissing:
            "The runtime slot has no manifest"
        case .invalidManifest:
            "The runtime slot manifest is damaged"
        case let .unsupportedManifest(version):
            "The runtime slot uses unsupported manifest version \(version)"
        case let .componentChanged(name):
            "The runtime component changed after installation: \(name)"
        case let .slotMissing(identifier):
            "The runtime slot is missing: \(identifier)"
        }
    }
}
