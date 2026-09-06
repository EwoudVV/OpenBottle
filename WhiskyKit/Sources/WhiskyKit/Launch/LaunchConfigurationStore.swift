//
//  LaunchConfigurationStore.swift
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

/// Captures and restores the files OpenBottle may change while preparing a launch.
public struct LaunchConfigurationStore: Sendable {
    public static let defaultMaximumSnapshots = 4

    private static let rendererDLLNames = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
        "nvngx.dll",
        "winemetal.dll"
    ]

    private static let rendererFileSuffixes = ["", ".orig", ".whisky-tmp"]

    private let vault: SaveVault
    private let restoreJournal: SaveRestoreJournal
    private let restoreEngine: SaveRestoreEngine

    public init(vault: SaveVault, restoreJournal: SaveRestoreJournal) {
        self.vault = vault
        self.restoreJournal = restoreJournal
        self.restoreEngine = SaveRestoreEngine(vault: vault, journal: restoreJournal)
    }

    /// The complete, deterministic set of launch-managed files in a bottle.
    public static func sources(for bottleURL: URL) -> [SaveSource] {
        var sources = [SaveSource(
            id: "bottle-settings",
            url: bottleURL.appending(path: "Metadata.plist"),
            kind: .file
        )]

        let windows = bottleURL.appending(path: "drive_c/windows")
        for architecture in ["system32", "syswow64"] {
            for name in rendererDLLNames {
                for suffix in rendererFileSuffixes {
                    let sourceID = "\(architecture)-\(name.replacingOccurrences(of: ".", with: "-"))\(suffixID(suffix))"
                    sources.append(SaveSource(
                        id: sourceID,
                        url: windows.appending(path: architecture).appending(path: "\(name)\(suffix)"),
                        kind: .file
                    ))
                }
            }
        }

        sources.append(SaveSource(
            id: "nvngx-model-config",
            url: bottleURL.appending(path: "drive_c/ProgramData/NVIDIA/NGX/models/nvngx_config.txt"),
            kind: .file
        ))
        return sources
    }

    public func capture(
        bottleURL: URL,
        bottleID: String,
        gameID: String,
        identifier: UUID,
        at date: Date = Date()
    ) throws -> SaveSnapshot {
        try vault.capture(
            bottleID: bottleID,
            gameID: gameID,
            sources: Self.sources(for: bottleURL),
            createdAt: date,
            identifier: identifier.uuidString.lowercased()
        )
    }

    /// Restores the baseline or finishes an interrupted restore first.
    public func restore(
        bottleURL: URL,
        bottleID: String,
        gameID: String,
        snapshotID: String,
        operationID: UUID
    ) async throws {
        let snapshotURL = try vault.snapshotURL(
            bottleID: bottleID,
            gameID: gameID,
            snapshotID: snapshotID
        )
        let snapshot = try vault.verify(snapshotAt: snapshotURL)
        let sources = Self.sources(for: bottleURL)
        if isCurrent(snapshot, sources: sources) { return }

        if let record = try? await restoreJournal.record(for: operationID), !record.stage.isTerminal {
            _ = try await restoreEngine.recover(record, sources: sources)
            if isCurrent(snapshot, sources: sources) { return }
        }

        let restoreID = try await nextRestoreID(after: operationID)
        _ = try await restoreEngine.restore(
            snapshotAt: snapshotURL,
            sources: sources,
            identifier: restoreID
        )
    }

    public func enforceRetention(
        bottleID: String,
        gameID: String,
        protectedSnapshotID: String,
        maximumSnapshots: Int = defaultMaximumSnapshots
    ) throws {
        try vault.enforceRetention(
            bottleID: bottleID,
            gameID: gameID,
            maximumSnapshots: max(1, maximumSnapshots),
            protectedSnapshotIDs: [protectedSnapshotID]
        )
    }

    private func isCurrent(_ snapshot: SaveSnapshot, sources: [SaveSource]) -> Bool {
        do {
            try vault.verifyRestoreTargets(snapshot: snapshot, sources: sources)
            return true
        } catch {
            return false
        }
    }

    private func nextRestoreID(after operationID: UUID) async throws -> UUID {
        do {
            _ = try await restoreJournal.record(for: operationID)
            return UUID()
        } catch SaveRestoreJournalError.recordMissing {
            return operationID
        } catch {
            return UUID()
        }
    }

    private static func suffixID(_ suffix: String) -> String {
        switch suffix {
        case ".orig": "-original"
        case ".whisky-tmp": "-temporary"
        default: ""
        }
    }
}
