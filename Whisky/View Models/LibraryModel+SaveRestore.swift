//
//  LibraryModel+SaveRestore.swift
//  Whisky
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

import AppKit
import Foundation
import UniformTypeIdentifiers
import WhiskyKit

struct LibraryRestoreSheet: Identifiable {
    enum Target {
        case steam(SteamGame)
        case program(gameID: String, sources: [SaveSource])
    }

    let row: LibraryRow
    let target: Target
    let inventory: SaveSnapshotInventory

    var id: String { row.id }
}

enum LibrarySaveError: LocalizedError {
    case gameRunning
    case gameUnavailable

    var errorDescription: String? {
        switch self {
        case .gameRunning:
            String(localized: "library.saves.gameRunning")
        case .gameUnavailable:
            String(localized: "library.saves.gameUnavailable")
        }
    }
}

extension LibraryModel {
    func canManageSaves(for row: LibraryRow) -> Bool {
        !row.item.isLauncher
    }

    func showRestorePoints(for row: LibraryRow, bottles: [Bottle]) async {
        do {
            guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else {
                throw LibrarySaveError.gameUnavailable
            }
            switch row.item.launch {
            case .steam:
                let target = try steamTarget(for: row, bottles: bottles)
                let inventory = try await saveSafety.inventory(
                    game: target.game,
                    bottleURL: target.bottle.url
                )
                restoreSheet = LibraryRestoreSheet(
                    row: row,
                    target: .steam(target.game),
                    inventory: inventory
                )
            case let .program(url):
                let plan = try ProgramLaunchPlanner.resolve(
                    programURL: url,
                    bottleURL: bottle.url
                )
                let inventory = try saveSafety.inventory(
                    gameID: plan.gameID,
                    bottleURL: bottle.url
                )
                restoreSheet = LibraryRestoreSheet(
                    row: row,
                    target: .program(gameID: plan.gameID, sources: plan.saveSources),
                    inventory: inventory
                )
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func restore(
        _ snapshot: SaveSnapshot,
        from sheet: LibraryRestoreSheet,
        bottles: [Bottle]
    ) async {
        let entryID = sheet.row.id
        guard !restoringEntryIDs.contains(entryID) else { return }
        restoringEntryIDs.insert(entryID)
        defer { restoringEntryIDs.remove(entryID) }

        do {
            guard let bottle = bottles.first(where: { $0.url == sheet.row.item.bottleURL }) else {
                throw LibrarySaveError.gameUnavailable
            }
            switch sheet.target {
            case let .steam(game):
                let running = await orchestrator(for: bottle).runningAppIDs(in: [game])
                guard !running.contains(game.appId) else {
                    throw LibrarySaveError.gameRunning
                }
                _ = try await saveSafety.restore(
                    snapshot: snapshot,
                    game: game,
                    bottleURL: bottle.url
                )
            case let .program(gameID, sources):
                guard await !Wine.isWineserverRunning(for: bottle) else {
                    throw LibrarySaveError.gameRunning
                }
                _ = try await saveSafety.restore(
                    snapshot: snapshot,
                    gameID: gameID,
                    sources: sources,
                    bottleURL: bottle.url
                )
            }
            restoreSheet = nil
            toast = ToastData(
                message: String(localized: "library.saves.restored"),
                style: .success
            )
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func steamTarget(
        for row: LibraryRow,
        bottles: [Bottle]
    ) throws -> (bottle: Bottle, game: SteamGame) {
        guard case let .steam(appID) = row.item.launch,
              let bottle = bottles.first(where: { $0.url == row.item.bottleURL }),
              let game = SteamLibrary.enumerate(bottleURL: bottle.url).first(where: { $0.appId == appID })
        else {
            throw LibrarySaveError.gameUnavailable
        }
        return (bottle, game)
    }
}

private struct LibraryCompatibilityTarget {
    let gameID: String
    let steamAppID: Int?
    let executableName: String?
    let installURL: URL
    let programURL: URL?
    let launcher: LauncherType?
    let entry: GameDBEntry?
    let variant: GameConfigVariant?
    let profileProvenance: [String]
    let backend: GraphicsBackend
}

extension LibraryModel {
    func exportCompatibilityReport(for row: LibraryRow, bottles: [Bottle]) async {
        do {
            let data = try await compatibilityReportData(for: row, bottles: bottles)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = CompatibilityReportExporter.suggestedFilename(
                gameName: row.item.name
            )
            panel.prompt = "Export"
            panel.message = "Review this JSON before sharing it. "
                + "It contains no paths, saves, accounts, tokens, or raw logs."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            toast = ToastData(
                message: "Exported a compatibility report for \(row.item.name).",
                style: .success
            )
        } catch {
            reportError = error.localizedDescription
        }
    }

    func compatibilityReportData(
        for row: LibraryRow,
        bottles: [Bottle]
    ) async throws -> Data {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else {
            throw LibrarySaveError.gameUnavailable
        }
        let hardware = HardwareProfile.current()
        let entries = GameDBLoader.loadDefaults()
        let target = try compatibilityTarget(
            for: row,
            bottle: bottle,
            entries: entries,
            hardware: hardware
        )
        let bottleID = BottleLaunchIdentity.id(for: bottle.url)
        let (runtime, runtimeFinding) = resolveRuntime(
            bottleID: bottleID,
            gameID: target.gameID
        )
        let preflight = await compatibilityPreflight(
            target: target,
            bottle: bottle,
            runtime: runtime,
            runtimeFinding: runtimeFinding
        )
        let lastLaunch = await lastLaunchRecord(
            bottleID: bottleID,
            gameID: target.gameID
        )
        var input = CompatibilityReportInput(
            application: compatibilityApplicationInfo(),
            game: CompatibilityGameInfo(
                name: row.item.name,
                source: row.item.source.rawValue,
                steamAppID: target.steamAppID,
                executableName: target.executableName
            ),
            hardware: hardware,
            runtime: runtime,
            preflight: preflight
        )
        input.databaseEntry = target.entry
        input.variant = target.variant
        input.profileProvenance = target.profileProvenance
        input.savePolicy = savePolicy(for: row)
        input.lastLaunch = lastLaunch
        let report = CompatibilityReportExporter.make(input)
        return try CompatibilityReportExporter.data(for: report)
    }

    private func compatibilityApplicationInfo() -> CompatibilityApplicationInfo {
        CompatibilityApplicationInfo(
            name: ProductIdentity.name,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        )
    }

    private func compatibilityTarget(
        for row: LibraryRow,
        bottle: Bottle,
        entries: [GameDBEntry],
        hardware: HardwareProfile
    ) throws -> LibraryCompatibilityTarget {
        let applied = GameConfigSnapshot.load(from: bottle.url)
        switch row.item.launch {
        case let .program(url):
            return try programCompatibilityTarget(
                url: url,
                bottle: bottle,
                entries: entries,
                applied: applied
            )
        case let .steam(appID):
            return try steamCompatibilityTarget(
                appID: appID,
                bottle: bottle,
                entries: entries,
                applied: applied,
                hardware: hardware
            )
        }
    }

    private func programCompatibilityTarget(
        url: URL,
        bottle: Bottle,
        entries: [GameDBEntry],
        applied: GameConfigSnapshot?
    ) throws -> LibraryCompatibilityTarget {
        let plan = try ProgramLaunchPlanner.resolve(
            programURL: url,
            bottleURL: bottle.url,
            appliedConfiguration: applied,
            entries: entries
        )
        return LibraryCompatibilityTarget(
            gameID: plan.gameID,
            steamAppID: nil,
            executableName: url.lastPathComponent,
            installURL: plan.installURL,
            programURL: url,
            launcher: LauncherType.detect(from: url),
            entry: plan.entry,
            variant: plan.variant,
            profileProvenance: plan.launchPlan.provenance,
            backend: plan.launchPlan.overrides.graphicsBackend ?? bottle.settings.graphicsBackend
        )
    }

    private func steamCompatibilityTarget(
        appID: Int,
        bottle: Bottle,
        entries: [GameDBEntry],
        applied: GameConfigSnapshot?,
        hardware: HardwareProfile
    ) throws -> LibraryCompatibilityTarget {
        guard let game = SteamLibrary.enumerate(bottleURL: bottle.url)
            .first(where: { $0.appId == appID })
        else { throw LibrarySaveError.gameUnavailable }
        let match = GameMatcher.bestMatch(
            metadata: ProgramMetadata(exeName: "", steamAppId: appID),
            against: entries,
            hardwareProfile: hardware
        )
        let appliedVariant = applied.flatMap { selection -> GameConfigVariant? in
            guard selection.appliedEntryId == match?.entry.id else { return nil }
            return match?.entry.variants.first { $0.id == selection.appliedVariantId }
        }
        let plan = LaunchResolver.plan(
            steamAppId: appID,
            appliedConfiguration: applied,
            entries: entries
        )
        return LibraryCompatibilityTarget(
            gameID: match?.entry.id ?? "steam-\(appID)",
            steamAppID: appID,
            executableName: nil,
            installURL: game.installURL,
            programURL: nil,
            launcher: nil,
            entry: match?.entry,
            variant: appliedVariant ?? match?.recommendedVariant,
            profileProvenance: plan.provenance,
            backend: plan.overrides.graphicsBackend ?? bottle.settings.graphicsBackend
        )
    }

    private func compatibilityPreflight(
        target: LibraryCompatibilityTarget,
        bottle: Bottle,
        runtime: RuntimeSelection,
        runtimeFinding: LaunchPreflightFinding?
    ) async -> LaunchPreflightReport {
        let evaluated = await LaunchPreflight.evaluate(LaunchPreflightInput(
            bottleURL: bottle.url,
            programURL: target.programURL,
            installURL: target.installURL,
            entry: target.entry,
            launcher: target.launcher,
            backend: target.backend,
            runtime: runtime
        ))
        return LaunchPreflightReport(
            findings: evaluated.findings + [runtimeFinding].compactMap { $0 },
            resolvedBackend: evaluated.resolvedBackend,
            runtimeSlotID: evaluated.runtimeSlotID
        )
    }

    private func lastLaunchRecord(
        bottleID: String,
        gameID: String
    ) async -> LaunchTransactionRecord? {
        let journal = LaunchTransactionJournal(
            rootURL: WhiskyWineInstaller.applicationFolder
                .appending(path: "Launch Safety")
                .appending(path: "Transactions")
        )
        let records = await (try? journal.records()) ?? []
        return records.last { $0.bottleID == bottleID && $0.gameID == gameID }
    }

    private func resolveRuntime(
        bottleID: String,
        gameID: String
    ) -> (RuntimeSelection, LaunchPreflightFinding?) {
        do {
            return try (RuntimeResolver.live().resolve(bottleID: bottleID, gameID: gameID), nil)
        } catch {
            let fallback = RuntimeSelection(
                slotID: nil,
                libraryURL: WhiskyWineInstaller.legacyLibraryFolder,
                manifest: nil,
                reason: "runtime resolution failed"
            )
            let finding = LaunchPreflightFinding(
                id: "runtime-resolution-failed",
                severity: .blocked,
                title: "Runtime selection failed",
                detail: error.localizedDescription,
                nextAction: "Choose a verified runtime in the library toolbar."
            )
            return (fallback, finding)
        }
    }
}
