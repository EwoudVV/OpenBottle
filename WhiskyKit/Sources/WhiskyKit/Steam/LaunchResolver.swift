//
//  LaunchResolver.swift
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

/// The resolved configuration for launching one game once.
///
/// Nothing in a plan is persisted: GameDB recommendations are applied
/// per launch, so two games in the same bottle never fight over
/// bottle-wide settings.
public struct LaunchPlan: Sendable {
    /// Per-launch program overrides: the user's persisted overrides with
    /// GameDB variant settings filling any field the user left unset.
    public let overrides: ProgramOverrides
    /// Extra environment for the ``EnvironmentLayer/gameProfile`` layer.
    public let gameProfileEnvironment: [String: String]
    /// Human-readable notes on where the configuration came from, for
    /// logging and provenance UI.
    public let provenance: [String]
}

/// Turns a Steam App ID into a ``LaunchPlan`` by matching the GameDB and
/// merging its selected or recommended variant under the user's own overrides.
public enum LaunchResolver {
    /// Builds the launch plan for a game.
    ///
    /// - Parameters:
    ///   - steamAppId: The game's Steam App ID (a hard identifier for
    ///     ``GameMatcher``, so no fuzzy-match risk).
    ///   - exeName: Optional executable name hint for matching.
    ///   - userOverrides: The user's persisted per-program overrides. Every
    ///     non-nil field wins over the GameDB recommendation.
    ///   - appliedConfiguration: The configuration currently applied to the
    ///     bottle. Its variant is used only when its entry and variant IDs both
    ///     match the current database; stale selections fall back to the default.
    ///   - entries: The GameDB entries to match against. Defaults to the
    ///     bundled database.
    /// - Returns: A plan; without a GameDB match it simply carries the user
    ///   overrides and empty profile environment.
    public static func plan(
        steamAppId: Int,
        exeName: String? = nil,
        userOverrides: ProgramOverrides? = nil,
        appliedConfiguration: GameConfigSnapshot? = nil,
        entries: [GameDBEntry]? = nil
    ) -> LaunchPlan {
        plan(
            metadata: ProgramMetadata(exeName: exeName ?? "", steamAppId: steamAppId),
            userOverrides: userOverrides,
            appliedConfiguration: appliedConfiguration,
            entries: entries
        )
    }

    /// Builds the same per-launch plan for a direct executable or another store.
    public static func plan(
        metadata: ProgramMetadata,
        userOverrides: ProgramOverrides? = nil,
        appliedConfiguration: GameConfigSnapshot? = nil,
        entries: [GameDBEntry]? = nil
    ) -> LaunchPlan {
        let database = entries ?? GameDBLoader.loadDefaults()

        guard let match = GameMatcher.bestMatch(metadata: metadata, against: database) else {
            return LaunchPlan(
                overrides: userOverrides ?? ProgramOverrides(),
                gameProfileEnvironment: [:],
                provenance: []
            )
        }

        let appliedVariant = appliedConfiguration.flatMap { selection -> GameConfigVariant? in
            guard selection.appliedEntryId == match.entry.id else { return nil }
            return match.entry.variants.first { $0.id == selection.appliedVariantId }
        }
        guard let variant = appliedVariant ?? match.recommendedVariant else {
            return LaunchPlan(
                overrides: userOverrides ?? ProgramOverrides(),
                gameProfileEnvironment: [:],
                provenance: []
            )
        }

        let overrides = merge(variant: variant.settings, dllOverrides: variant.dllOverrides, under: userOverrides)

        return LaunchPlan(
            overrides: overrides,
            gameProfileEnvironment: variant.environmentVariables ?? [:],
            provenance: [
                "gamedb: \(match.entry.title) — \(variant.label) (\(match.explanation))"
            ]
        )
    }

    /// Fills GameDB variant settings into every field the user left unset.
    ///
    /// Bottle-level variant settings (`avxEnabled`, `sequoiaCompatMode`) and
    /// `winetricksVerbs` are not mapped: the first two have no per-program
    /// equivalent and verbs are an install-time action, not launch config.
    static func merge(
        variant: GameConfigVariantSettings,
        dllOverrides: [DLLOverrideEntry]?,
        under userOverrides: ProgramOverrides?
    ) -> ProgramOverrides {
        var merged = userOverrides ?? ProgramOverrides()

        merged.graphicsBackend = merged.graphicsBackend ?? variant.graphicsBackend
        merged.dxvk = merged.dxvk ?? variant.dxvk
        merged.dxvkAsync = merged.dxvkAsync ?? variant.dxvkAsync
        merged.enhancedSync = merged.enhancedSync ?? variant.enhancedSync
        merged.forceD3D11 = merged.forceD3D11 ?? variant.forceD3D11
        merged.shaderCacheEnabled = merged.shaderCacheEnabled ?? variant.shaderCacheEnabled
        merged.performancePreset = merged.performancePreset
            ?? variant.performancePreset.flatMap(PerformancePreset.init(rawValue:))
        merged.dllOverrides = merged.dllOverrides ?? dllOverrides

        return merged
    }
}
