//
//  LegacyBottleImport.swift
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
import os.log

/// Read-only discovery of bottles created by existing Whisky installations.
///
/// Discovery never constructs a ``Bottle`` or writes to the source. ``BottleImporter``
/// performs the separate verified copy when the user chooses to import one.
public enum LegacyBottleImport {
    private static let logger = Logger(
        subsystem: Bundle.whiskyBundleIdentifier,
        category: "LegacyBottleImport"
    )

    /// Bundle identifier of the archived original Whisky app.
    public static let legacyBundleIdentifier = "com.isaacmarovitz.Whisky"

    public struct Source: Equatable, Sendable {
        public let bundleIdentifier: String
        public let containerDirectory: URL

        public init(bundleIdentifier: String, containerDirectory: URL) {
            self.bundleIdentifier = bundleIdentifier
            self.containerDirectory = containerDirectory
        }
    }

    /// Every known Whisky container, ordered with the user's current fork first.
    public static var sources: [Source] {
        ProductIdentity.legacyBundleIdentifiers.map { bundleIdentifier in
            Source(
                bundleIdentifier: bundleIdentifier,
                containerDirectory: FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Containers")
                    .appending(path: bundleIdentifier)
            )
        }
    }

    /// `~/Library/Containers/com.isaacmarovitz.Whisky`.
    public static var legacyContainerDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Containers")
            .appending(path: legacyBundleIdentifier)
    }

    /// Minimal decode of the original app's bottle registry. Same plist shape as
    /// ``BottleData`` — we only need the registered paths.
    private struct LegacyRegistry: Decodable {
        var paths: [URL]
    }

    /// Whether the original app's container exists at all. Used to decide whether the
    /// migration option is worth offering in the UI.
    public static func legacyContainerExists(at container: URL = legacyContainerDirectory) -> Bool {
        FileManager.default.fileExists(atPath: container.path(percentEncoded: false))
    }

    /// URLs of original-app bottles that are valid (contain a `Metadata.plist`) and are
    /// not already registered in `existingPaths`.
    ///
    /// Sources, in order: the original app's `BottleVM.plist` registry (which also covers
    /// bottles stored at custom paths outside the default Bottles directory), then a scan
    /// of the default `Bottles` directory as a fallback. Results are de-duplicated and
    /// sorted by directory name.
    ///
    /// - Parameters:
    ///   - legacyContainer: the original app's container directory (injectable for testing).
    ///   - existingPaths: bottle paths already registered in this fork, to avoid duplicates.
    public static func importableBottleURLs(
        legacyContainer: URL = legacyContainerDirectory,
        existingPaths: [URL]
    ) -> [URL] {
        let existing = Set(existingPaths.map(comparablePath))
        var candidates: [URL] = []

        // 1. The registry plist lists every bottle the original app knew about, including
        //    bottles stored at custom paths outside the Bottles directory.
        let registryURL = legacyContainer.appending(path: "BottleVM").appendingPathExtension("plist")
        if let data = try? Data(contentsOf: registryURL),
           let registry = try? PropertyListDecoder().decode(LegacyRegistry.self, from: data) {
            candidates.append(contentsOf: registry.paths)
        }

        // 2. Scan the default Bottles directory in case the registry is missing or stale.
        let bottlesDir = legacyContainer.appending(path: "Bottles")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: bottlesDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            candidates.append(contentsOf: entries)
        }

        var seen = Set<String>()
        var result: [URL] = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            let key = comparablePath(standardized)
            guard !existing.contains(key), seen.insert(key).inserted else { continue }
            guard isBottle(at: standardized) else { continue }
            result.append(standardized)
        }

        logger.info("Discovered \(result.count) importable legacy bottle(s)")
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// An importable original-app bottle, with the display name read from its settings.
    public struct DiscoveredBottle: Identifiable, Hashable, Sendable {
        /// The bottle's directory URL (also its identity).
        public let url: URL
        /// The bottle's display name, read from its settings (falls back to the directory name).
        public let name: String
        /// The Whisky installation that owns the untouched source bottle.
        public let sourceBundleIdentifier: String
        public var id: URL {
            url
        }

        public init(url: URL, name: String, sourceBundleIdentifier: String) {
            self.url = url
            self.name = name
            self.sourceBundleIdentifier = sourceBundleIdentifier
        }
    }

    /// Like ``importableBottleURLs(legacyContainer:existingPaths:)`` but also reads each bottle's
    /// display name. Names are read **non-destructively** (see ``readOnlyName(at:)``) — discovery
    /// must never mutate the original app's bottles.
    public static func importableBottles(
        legacyContainer: URL = legacyContainerDirectory,
        existingPaths: [URL]
    ) -> [DiscoveredBottle] {
        importableBottleURLs(legacyContainer: legacyContainer, existingPaths: existingPaths).map { url in
            DiscoveredBottle(
                url: url,
                name: readOnlyName(at: url) ?? url.lastPathComponent,
                sourceBundleIdentifier: legacyContainer.lastPathComponent
            )
        }
    }

    /// Discovers bottles from every known Whisky installation without opening them as `Bottle` objects.
    public static func allImportableBottles(existingPaths: [URL]) -> [DiscoveredBottle] {
        allImportableBottles(sources: sources, existingPaths: existingPaths)
    }

    /// Injectable source list for migration tests and future Whisky variants.
    public static func allImportableBottles(
        sources: [Source],
        existingPaths: [URL]
    ) -> [DiscoveredBottle] {
        var seen = Set<String>()
        var bottles: [DiscoveredBottle] = []
        for source in sources where legacyContainerExists(at: source.containerDirectory) {
            let found = importableBottleURLs(
                legacyContainer: source.containerDirectory,
                existingPaths: existingPaths
            )
            for url in found where seen.insert(comparablePath(url)).inserted {
                bottles.append(DiscoveredBottle(
                    url: url,
                    name: readOnlyName(at: url) ?? url.lastPathComponent,
                    sourceBundleIdentifier: source.bundleIdentifier
                ))
            }
        }
        return bottles.sorted {
            if $0.name != $1.name {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.url.path < $1.url.path
        }
    }

    /// Reads a bottle's display name from its `Metadata.plist` **without writing anything**.
    ///
    /// This decodes `BottleSettings` directly via `PropertyListDecoder` (whose `init(from:)` is
    /// pure). It deliberately does **not** use `BottleSettings.decode(from:)` or construct a
    /// `Bottle`: both of those rewrite the metadata file when the bottle's file/wine version
    /// differs from the current app's defaults — which a bottle from the original app almost
    /// always does — and that would silently mutate the user's original bottles just by opening
    /// the migration sheet. Returns `nil` if the metadata is missing or undecodable.
    private static func readOnlyName(at bottleURL: URL) -> String? {
        let metadata = bottleURL.appending(path: "Metadata").appendingPathExtension("plist")
        guard let data = try? Data(contentsOf: metadata),
              let settings = try? PropertyListDecoder().decode(BottleSettings.self, from: data)
        else { return nil }
        return settings.name
    }

    /// A directory is treated as a bottle when it contains a `Metadata.plist`, the marker
    /// ``Bottle`` and ``BottleData`` use to recognise a real bottle on disk.
    private static func isBottle(at url: URL) -> Bool {
        let metadata = url.appending(path: "Metadata").appendingPathExtension("plist")
        return FileManager.default.fileExists(atPath: metadata.path(percentEncoded: false))
    }

    private static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
