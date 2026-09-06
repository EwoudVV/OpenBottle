//
//  GameSaveDiscovery.swift
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

/// Bounded, local save discovery for games that do not yet have a complete manifest.
public enum GameSaveDiscovery {
    private static let maximumDepth = 3
    private static let maximumVisitedItems = 5_000
    private static let maximumSources = 32
    private static let ignoredTokens: Set<String> = [
        "application",
        "client",
        "game",
        "games",
        "launcher",
        "shipping",
        "steam",
        "win32",
        "win64",
        "windows"
    ]

    public static func steamSources(
        game: SteamGame,
        bottleURL: URL,
        entry: GameDBEntry?,
        wineUserName: String? = nil
    ) -> [SaveSource] {
        let cloud = steamUserdataSources(game: game, bottleURL: bottleURL)
        let profile = profileSources(
            bottleURL: bottleURL,
            names: names(
                title: entry?.title ?? game.name,
                aliases: entry?.aliases ?? [],
                executableNames: entry?.exeNames ?? Array(
                    SteamLibrary.executableNames(under: game.installURL)
                )
            ),
            wineUserName: wineUserName
        )
        return nonOverlapping(cloud + profile)
    }

    public static func programSources(
        programURL: URL,
        bottleURL: URL,
        entry: GameDBEntry?,
        wineUserName: String? = nil
    ) -> [SaveSource] {
        let title = entry?.title ?? programURL.deletingPathExtension().lastPathComponent
        let aliases = entry?.aliases ?? [programURL.deletingLastPathComponent().lastPathComponent]
        let executableNames = (entry?.exeNames ?? []) + [programURL.lastPathComponent]
        return profileSources(
            bottleURL: bottleURL,
            names: names(title: title, aliases: aliases, executableNames: executableNames),
            wineUserName: wineUserName
        )
    }

    public static func merging(
        declared: [SaveSource],
        discovered: [SaveSource]
    ) -> [SaveSource] {
        var merged = declared
        var identifiers = Set(declared.map(\.id))
        for source in discovered where !identifiers.contains(source.id) {
            guard !merged.contains(where: { SaveVault.pathsOverlap($0.url, source.url) }) else {
                continue
            }
            merged.append(source)
            identifiers.insert(source.id)
        }
        return merged
    }

    private static func steamUserdataSources(
        game: SteamGame,
        bottleURL: URL
    ) -> [SaveSource] {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL) else { return [] }
        let userdata = steamRoot.appending(path: "userdata")
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: userdata,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return accounts.compactMap { account in
            guard (try? account.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let appData = account.appending(path: String(game.appId))
            guard FileManager.default.fileExists(atPath: appData.path(percentEncoded: false)) else {
                return nil
            }
            return SaveSource(
                id: "steam-userdata-\(opaqueID(account.lastPathComponent))",
                url: appData,
                kind: .directory
            )
        }
    }

    private static func profileSources(
        bottleURL: URL,
        names: Set<String>,
        wineUserName: String?
    ) -> [SaveSource] {
        guard !names.isEmpty else { return [] }
        let context = GameSaveContext(
            bottleURL: bottleURL,
            gameInstallURL: bottleURL,
            wineUserName: wineUserName
        )
        let profile = bottleURL.appending(path: "drive_c/users/\(context.wineUserName)")
        let roots = [
            profile.appending(path: "Documents"),
            profile.appending(path: "Saved Games"),
            profile.appending(path: "AppData/Roaming"),
            profile.appending(path: "AppData/Local"),
            profile.appending(path: "AppData/LocalLow")
        ]
        return nonOverlapping(roots.flatMap { scan(root: $0, matching: names, bottleURL: bottleURL) })
    }

    private static func scan(
        root: URL,
        matching names: Set<String>,
        bottleURL: URL
    ) -> [SaveSource] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        else { return [] }

        var sources: [SaveSource] = []
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > maximumVisitedItems || sources.count >= maximumSources { break }
            let relative = item.pathComponents.dropFirst(root.pathComponents.count)
            let depth = relative.count
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]), values.isSymbolicLink != true
            else {
                enumerator.skipDescendants()
                continue
            }
            guard matches(item.deletingPathExtension().lastPathComponent, names: names) else {
                continue
            }
            if values.isDirectory == true {
                sources.append(source(for: item, kind: .directory, bottleURL: bottleURL))
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                sources.append(source(for: item, kind: .file, bottleURL: bottleURL))
            }
        }
        return sources
    }

    private static func source(
        for url: URL,
        kind: SaveSourceKind,
        bottleURL: URL
    ) -> SaveSource {
        let relative = (try? SaveVault.relativePath(of: url, below: bottleURL))
            ?? url.path(percentEncoded: false)
        return SaveSource(
            id: "discovered-\(opaqueID(relative))",
            url: url,
            kind: kind
        )
    }

    private static func names(
        title: String,
        aliases: [String],
        executableNames: [String]
    ) -> Set<String> {
        let supplied = [title] + aliases + executableNames.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
        var result: Set<String> = []
        for value in supplied {
            let words = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 4 && !ignoredTokens.contains($0) }
            result.formUnion(words)
            let joined = words.joined()
            if joined.count >= 4 {
                result.insert(joined)
            }
        }
        return result
    }

    private static func matches(_ value: String, names: Set<String>) -> Bool {
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        guard normalized.count >= 4 else { return false }
        return names.contains { normalized.contains($0) || $0.contains(normalized) }
    }

    private static func nonOverlapping(_ sources: [SaveSource]) -> [SaveSource] {
        var accepted: [SaveSource] = []
        for source in sources.sorted(by: { $0.url.path.count < $1.url.path.count }) {
            guard !accepted.contains(where: { SaveVault.pathsOverlap($0.url, source.url) }) else {
                continue
            }
            accepted.append(source)
        }
        return accepted.sorted { $0.id < $1.id }
    }

    private static func opaqueID(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
