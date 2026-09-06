//
//  RuntimeSlotManager.swift
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

/// Installs immutable runtime directories and changes only a tiny selected-slot index.
public struct RuntimeSlotManager: Sendable {
    public static let manifestFileName = "RuntimeManifest.json"
    public static let indexFileName = "index.json"

    public let rootURL: URL

    private var slotsURL: URL { rootURL.appending(path: "Slots") }
    private var indexURL: URL { rootURL.appending(path: Self.indexFileName) }

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public static func live() -> RuntimeSlotManager {
        RuntimeSlotManager(
            rootURL: WhiskyWineInstaller.applicationFolder.appending(path: "Runtimes")
        )
    }

    @discardableResult
    public func install(
        tarball: URL,
        channel: RuntimeChannel,
        sourceURL: URL? = nil,
        at date: Date = Date()
    ) throws -> RuntimeSlot {
        guard FileManager.default.fileExists(atPath: tarball.path(percentEncoded: false)) else {
            throw RuntimeSlotError.archiveMissing
        }
        guard let archiveSHA256 = WhiskyWineInstaller.sha256(ofFileAt: tarball) else {
            throw RuntimeSlotError.archiveUnreadable
        }
        try FileManager.default.createDirectory(at: slotsURL, withIntermediateDirectories: true)
        let staging = slotsURL.appending(
            path: ".install-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        var removeStaging = true
        defer {
            if removeStaging {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        let (libraryURL, runtimeInfo) = try extract(tarball: tarball, to: staging)

        let version = Self.versionString(runtimeInfo)
        let identifier = "\(channel.rawValue)-\(version)-\(archiveSHA256.prefix(12))"
        let manifest = try makeManifest(RuntimeManifestInput(
            id: identifier,
            channel: channel,
            version: version,
            runtimeInfo: runtimeInfo,
            libraryURL: libraryURL,
            sourceURL: sourceURL,
            archiveSHA256: archiveSHA256,
            date: date
        ))
        try write(manifest, to: staging.appending(path: Self.manifestFileName))
        let destination = slotsURL.appending(path: identifier, directoryHint: .isDirectory)
        let slot: RuntimeSlot
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            let existing = try loadSlot(at: destination)
            guard existing.manifest.archiveSHA256 == archiveSHA256 else {
                throw RuntimeSlotError.invalidManifest
            }
            try verify(existing)
            slot = existing
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
            removeStaging = false
            slot = try loadSlot(at: destination)
            try verify(slot)
        }
        try select(slotID: slot.id, channel: channel)
        return slot
    }

    public func slots() throws -> [RuntimeSlot] {
        guard FileManager.default.fileExists(atPath: slotsURL.path(percentEncoded: false)) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: slotsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return try loadSlot(at: url)
        }.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func slot(id: String) throws -> RuntimeSlot {
        try SaveVault.validateIdentifier(id)
        let url = slotsURL.appending(path: id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw RuntimeSlotError.slotMissing(id)
        }
        return try loadSlot(at: url)
    }

    public func selectedSlot(for channel: RuntimeChannel) throws -> RuntimeSlot? {
        let index = try loadIndex()
        let identifier = switch channel {
        case .stable, .imported: index.stableSlotID
        case .preview: index.previewSlotID
        }
        guard let identifier else { return nil }
        return try slot(id: identifier)
    }

    public func defaultSlot() throws -> RuntimeSlot? {
        if let stable = try selectedSlot(for: .stable) {
            return stable
        }
        return try selectedSlot(for: .preview)
    }

    public func defaultLibraryURL() -> URL? {
        try? defaultSlot()?.libraryURL
    }

    public func select(slotID: String, channel: RuntimeChannel) throws {
        let slot = try slot(id: slotID)
        try verify(slot)
        var index = try loadIndex()
        switch channel {
        case .stable, .imported:
            index.stableSlotID = slotID
        case .preview:
            index.previewSlotID = slotID
        }
        try write(index, to: indexURL)
    }

    public func verify(_ slot: RuntimeSlot) throws {
        guard slot.manifest.schemaVersion == RuntimeSlotManifest.currentSchemaVersion,
              slot.manifest.id == slot.url.lastPathComponent,
              WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: slot.libraryURL)
        else {
            throw RuntimeSlotError.invalidManifest
        }
        for component in slot.manifest.components {
            guard let path = component.representativePath,
                  let expected = component.sha256
            else { continue }
            let url = slot.libraryURL.appending(path: path)
            guard WhiskyWineInstaller.sha256(ofFileAt: url) == expected else {
                throw RuntimeSlotError.componentChanged(component.name)
            }
        }
    }

    public func removeAllSlots() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }
}

private extension RuntimeSlotManager {
    func extract(
        tarball: URL,
        to staging: URL
    ) throws -> (libraryURL: URL, runtimeInfo: WhiskyWineVersion) {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Tar.untar(tarBall: tarball, toURL: staging)
        let libraryURL = staging.appending(path: "Libraries")
        guard WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: libraryURL),
              let runtimeInfo = WhiskyWineInstaller.whiskyWineInfo(
                  at: libraryURL.appending(path: "WhiskyWineVersion.plist")
              )
        else {
            throw RuntimeSlotError.extractedRuntimeMissing
        }
        return (libraryURL, runtimeInfo)
    }

    func loadSlot(at url: URL) throws -> RuntimeSlot {
        let manifestURL = url.appending(path: Self.manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw RuntimeSlotError.manifestMissing
        }
        let manifest: RuntimeSlotManifest
        do {
            manifest = try JSONDecoder.openBottleRuntime.decode(
                RuntimeSlotManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw RuntimeSlotError.invalidManifest
        }
        guard manifest.schemaVersion == RuntimeSlotManifest.currentSchemaVersion else {
            throw RuntimeSlotError.unsupportedManifest(manifest.schemaVersion)
        }
        return RuntimeSlot(url: url, manifest: manifest)
    }

    func loadIndex() throws -> RuntimeSlotIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
            return RuntimeSlotIndex()
        }
        let index: RuntimeSlotIndex
        do {
            index = try JSONDecoder.openBottleRuntime.decode(
                RuntimeSlotIndex.self,
                from: Data(contentsOf: indexURL)
            )
        } catch {
            throw RuntimeSlotError.invalidManifest
        }
        guard index.schemaVersion == RuntimeSlotIndex.currentSchemaVersion else {
            throw RuntimeSlotError.unsupportedManifest(index.schemaVersion)
        }
        return index
    }

    func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func versionString(_ info: WhiskyWineVersion) -> String {
        "\(info.version.major).\(info.version.minor).\(info.version.patch)"
    }
}

private extension JSONDecoder {
    static var openBottleRuntime: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
