//
//  ProgramLaunchPlanner.swift
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

import CryptoKit
import Foundation

public struct ProgramLaunchPlan: Sendable {
    public let gameID: String
    public let saveSources: [SaveSource]
    public let launchPlan: LaunchPlan
    public let processNames: Set<String>
    public let entry: GameDBEntry?
    public let variant: GameConfigVariant?
    public let installURL: URL

    public init(
        gameID: String,
        saveSources: [SaveSource],
        launchPlan: LaunchPlan,
        processNames: Set<String>,
        entry: GameDBEntry?,
        variant: GameConfigVariant? = nil,
        installURL: URL
    ) {
        self.gameID = gameID
        self.saveSources = saveSources
        self.launchPlan = launchPlan
        self.processNames = processNames
        self.entry = entry
        self.variant = variant
        self.installURL = installURL
    }
}

/// Resolves a direct executable into the same profile and save inputs as a store game.
public enum ProgramLaunchPlanner {
    public static func resolve(
        programURL: URL,
        bottleURL: URL,
        userOverrides: ProgramOverrides? = nil,
        appliedConfiguration: GameConfigSnapshot? = nil,
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil
    ) throws -> ProgramLaunchPlan {
        let metadata = metadata(for: programURL, bottleURL: bottleURL)
        let match = GameMatcher.bestMatch(metadata: metadata, against: entries)
        let gameID = match?.entry.id ?? fallbackGameID(
            programURL: programURL,
            bottleURL: bottleURL
        )
        let declared = try GameSaveResolver.resolve(
            match?.entry.saveLocations ?? [],
            context: GameSaveContext(
                bottleURL: bottleURL,
                gameInstallURL: programURL.deletingLastPathComponent(),
                wineUserName: wineUserName
            )
        )
        let discovered = GameSaveDiscovery.programSources(
            programURL: programURL,
            bottleURL: bottleURL,
            entry: match?.entry,
            wineUserName: wineUserName
        )
        var processNames = Set(
            (match?.entry.exeNames ?? []) + [programURL.lastPathComponent]
        ).mapLowercased()
        if ["msi", "msix", "appx"].contains(programURL.pathExtension.lowercased()) {
            processNames.insert("msiexec.exe")
        }
        let appliedVariant = appliedConfiguration.flatMap { selection -> GameConfigVariant? in
            guard selection.appliedEntryId == match?.entry.id else { return nil }
            return match?.entry.variants.first { $0.id == selection.appliedVariantId }
        }
        return ProgramLaunchPlan(
            gameID: gameID,
            saveSources: GameSaveDiscovery.merging(
                declared: declared,
                discovered: discovered
            ),
            launchPlan: LaunchResolver.plan(
                metadata: metadata,
                userOverrides: userOverrides,
                appliedConfiguration: appliedConfiguration,
                entries: entries
            ),
            processNames: processNames,
            entry: match?.entry,
            variant: appliedVariant ?? match?.recommendedVariant,
            installURL: programURL.deletingLastPathComponent()
        )
    }

    public static func fallbackGameID(programURL: URL, bottleURL: URL) -> String {
        let programPath = programURL.standardizedFileURL.path(percentEncoded: false)
        let bottlePath = bottleURL.standardizedFileURL.path(percentEncoded: false)
        let identity: String = if programPath.hasPrefix("\(bottlePath)/") {
            String(programPath.dropFirst(bottlePath.count + 1))
        } else {
            programPath
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "program-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func metadata(for programURL: URL, bottleURL: URL) -> ProgramMetadata {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: programURL.path(percentEncoded: false)
        )
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        let programPath = programURL.standardizedFileURL.path(percentEncoded: false)
        let bottlePath = bottleURL.standardizedFileURL.path(percentEncoded: false)
        let installPath = programPath.hasPrefix("\(bottlePath)/")
            ? String(programPath.dropFirst(bottlePath.count + 1))
            : nil
        return ProgramMetadata(
            exeName: programURL.lastPathComponent,
            exeURL: programURL,
            fileSize: fileSize,
            installPath: installPath
        )
    }
}

private extension Set<String> {
    func mapLowercased() -> Set<String> {
        Set(map { $0.lowercased() })
    }
}
