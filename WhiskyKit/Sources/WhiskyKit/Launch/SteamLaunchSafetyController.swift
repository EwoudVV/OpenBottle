//
//  SteamLaunchSafetyController.swift
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

/// Steam's name for the preparation returned by the shared launch transaction.
public typealias SteamLaunchPreparation = LaunchSafetyPreparation

/// Resolves Steam identity and save paths before handing work to the shared transaction.
public struct SteamLaunchSafetyController: Sendable {
    private let controller: LaunchSafetyController
    private let entries: [GameDBEntry]
    private let wineUserName: String?
    private let savePolicyStore: GameSavePolicyStore

    public init(
        vault: SaveVault,
        journal: LaunchTransactionJournal,
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil,
        maximumSnapshots: Int = SaveVault.defaultMaximumSnapshots,
        configurationVault: SaveVault? = nil,
        configurationRestoreJournal: SaveRestoreJournal? = nil,
        savePolicyStore: GameSavePolicyStore? = nil
    ) {
        self.controller = LaunchSafetyController(
            saveVault: vault,
            journal: journal,
            configurationVault: configurationVault,
            configurationRestoreJournal: configurationRestoreJournal,
            maximumSaveSnapshots: maximumSnapshots
        )
        self.entries = entries
        self.wineUserName = wineUserName
        self.savePolicyStore = savePolicyStore ?? GameSavePolicyStore(
            rootURL: journal.rootURL.deletingLastPathComponent().appending(path: "Save Policies")
        )
    }

    public static func live(
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        wineUserName: String? = nil
    ) -> SteamLaunchSafetyController {
        let root = WhiskyWineInstaller.applicationFolder.appending(path: "Launch Safety")
        return SteamLaunchSafetyController(
            vault: SaveVault(rootURL: root.appending(path: "Save Vault")),
            journal: LaunchTransactionJournal(rootURL: root.appending(path: "Transactions")),
            entries: entries,
            wineUserName: wineUserName,
            configurationVault: SaveVault(
                rootURL: root.appending(path: "Configuration Vault")
            ),
            configurationRestoreJournal: SaveRestoreJournal(
                rootURL: root.appending(path: "Configuration Restore Transactions")
            ),
            savePolicyStore: .live()
        )
    }

    public func savePolicy(
        for game: SteamGame,
        bottleURL: URL
    ) async throws -> GameSavePolicy {
        try await savePolicyStore.policy(
            bottleID: BottleLaunchIdentity.id(for: bottleURL),
            gameID: SteamSavePolicyIdentity.gameID(appID: game.appId)
        )
    }

    /// Opens a journal record and captures every known save source before Steam starts.
    public func prepare(
        game: SteamGame,
        bottleURL: URL,
        identifier: UUID = UUID(),
        at date: Date = Date()
    ) async throws -> SteamLaunchPreparation {
        let plan = try SteamGameSavePlanner.resolve(
            game: game,
            bottleURL: bottleURL,
            entries: entries,
            wineUserName: wineUserName
        )
        return try await controller.begin(
            bottleURL: bottleURL,
            gameID: plan.gameID,
            saveSources: plan.sources,
            identifier: identifier,
            at: date
        )
    }

    @MainActor
    public func preflight(
        game: SteamGame,
        bottle: Bottle,
        preparation: SteamLaunchPreparation
    ) async -> LaunchPreflightReport {
        let entry = entries.first { $0.steamAppId == game.appId }
        let userOverrides = SteamLauncher.userOverrides(
            forInstallURL: game.installURL,
            bottle: bottle
        )
        let plan = LaunchResolver.plan(
            steamAppId: game.appId,
            userOverrides: userOverrides,
            appliedConfiguration: GameConfigSnapshot.load(from: bottle.url),
            entries: entries
        )
        let programURL = preferredExecutable(in: game.installURL, entry: entry)
        return await LaunchPreflight.evaluate(LaunchPreflightInput(
            bottleURL: bottle.url,
            programURL: programURL,
            installURL: game.installURL,
            entry: entry,
            launcher: nil,
            backend: plan.overrides.graphicsBackend ?? bottle.settings.graphicsBackend,
            runtime: preparation.runtimeSelection
        ))
    }

    @discardableResult
    public func markPrepared(
        _ preparation: SteamLaunchPreparation
    ) async throws -> LaunchTransactionRecord {
        try await controller.prepareConfiguration(preparation)
    }

    @discardableResult
    public func markLaunchRequested(
        _ preparation: SteamLaunchPreparation
    ) async throws -> LaunchTransactionRecord {
        try await controller.markLaunchRequested(preparation)
    }

    @discardableResult
    public func markMonitoring(
        _ preparation: SteamLaunchPreparation
    ) async throws -> LaunchTransactionRecord {
        try await controller.markMonitoring(preparation)
    }

    @discardableResult
    public func fail(
        _ preparation: SteamLaunchPreparation,
        code: String
    ) async throws -> LaunchTransactionRecord {
        try await controller.fail(preparation, code: code)
    }

    @discardableResult
    public func complete(
        _ preparation: SteamLaunchPreparation
    ) async throws -> LaunchTransactionRecord {
        try await controller.finish(preparation)
    }

    public func unfinished(bottleURL: URL) async throws -> [LaunchTransactionRecord] {
        try await controller.unfinished(bottleURL: bottleURL)
    }

    func game(
        for record: LaunchTransactionRecord,
        among games: [SteamGame]
    ) -> SteamGame? {
        SteamGameSavePlanner.game(for: record.gameID, among: games, entries: entries)
    }

    func resumeMonitoring(
        _ record: LaunchTransactionRecord,
        bottleURL: URL
    ) async throws -> SteamLaunchPreparation {
        try await controller.resumeMonitoring(record, bottleURL: bottleURL)
    }

    @discardableResult
    func finishInterrupted(
        _ record: LaunchTransactionRecord,
        bottleURL: URL
    ) async throws -> LaunchTransactionRecord {
        try await controller.finishInterrupted(record, bottleURL: bottleURL)
    }

    @discardableResult
    func finishAfterExit(
        _ preparation: SteamLaunchPreparation,
        game: SteamGame,
        bottleURL: URL
    ) async throws -> LaunchTransactionRecord {
        let plan = try SteamGameSavePlanner.resolve(
            game: game,
            bottleURL: bottleURL,
            entries: entries,
            wineUserName: wineUserName
        )
        return try await controller.finish(
            preparation.withSaveSources(plan.sources)
        )
    }

    private func preferredExecutable(
        in installURL: URL,
        entry: GameDBEntry?
    ) -> URL? {
        let executables = SteamLibrary.executableURLs(under: installURL)
        let preferredNames = Set((entry?.exeNames ?? []).map { $0.lowercased() })
        return executables.first { preferredNames.contains($0.lastPathComponent.lowercased()) }
            ?? executables.first
    }
}
