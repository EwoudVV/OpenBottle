//
//  SteamClientOrchestrator+LaunchSafety.swift
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

@MainActor
extension SteamClientOrchestrator {
    /// Reattaches durable records to running games and closes records whose game exited.
    public func recoverUnfinishedLaunches(games: [SteamGame]) async throws {
        guard let launchSafety else { return }
        let records = try await launchSafety.unfinished(bottleURL: bottle.url)
        let ownedTransactions = Set(launchTransactionIDs.values)
        let running = await runningImageNames()
        for record in records where !ownedTransactions.contains(record.id) {
            let game = launchSafety.game(for: record, among: games)
            let isRunning = game.map {
                !SteamLibrary.executableNames(under: $0.installURL).isDisjoint(with: running)
            } ?? false
            if let game,
               isRunning,
               [.launchRequested, .monitoring, .recoveryNeeded].contains(record.stage) {
                let preparation = try await launchSafety.resumeMonitoring(record)
                startExitMonitor(for: game, preparation: preparation)
            } else {
                _ = try await launchSafety.finishInterrupted(record)
            }
        }
    }

    public func runningAppIDs(in games: [SteamGame]) async -> Set<Int> {
        let running = await runningImageNames()
        return Set(games.compactMap { game in
            let names = SteamLibrary.executableNames(under: game.installURL)
            return names.isDisjoint(with: running) ? nil : game.appId
        })
    }

    func beginExitMonitoring(
        _ game: SteamGame,
        preparation: SteamLaunchPreparation?
    ) async {
        guard let preparation else { return }
        do {
            _ = try await launchSafety?.markMonitoring(preparation)
            startExitMonitor(for: game, preparation: preparation)
        } catch {
            await recordFailure(preparation, code: "game-monitor-start-failed")
            launchError = error.localizedDescription
        }
    }

    func recordFailure(_ preparation: SteamLaunchPreparation?, code: String) async {
        guard let preparation else { return }
        _ = try? await launchSafety?.fail(preparation, code: code)
    }

    func recordCancellationIfNeeded(_ preparation: SteamLaunchPreparation?) async -> Bool {
        guard Task.isCancelled else { return false }
        await recordFailure(preparation, code: "launch-cancelled")
        return true
    }

    private func startExitMonitor(
        for game: SteamGame,
        preparation: SteamLaunchPreparation
    ) {
        let identifier = preparation.transactionID
        exitMonitorTasks[identifier]?.cancel()
        exitMonitorTasks[identifier] = Task { [weak self] in
            await self?.monitorGameExit(game, preparation: preparation)
        }
    }

    private func monitorGameExit(
        _ game: SteamGame,
        preparation: SteamLaunchPreparation
    ) async {
        defer { exitMonitorTasks[preparation.transactionID] = nil }
        let names = SteamLibrary.executableNames(under: game.installURL)
        guard !names.isEmpty else {
            await complete(preparation)
            return
        }

        var absentChecks = 0
        while !Task.isCancelled {
            let running = await runningImageNames()
            absentChecks = running.isDisjoint(with: names) ? absentChecks + 1 : 0
            if absentChecks >= 2 {
                await complete(preparation)
                return
            }
            try? await Task.sleep(for: timing.trackingInterval)
        }
    }

    private func complete(_ preparation: SteamLaunchPreparation) async {
        do {
            _ = try await launchSafety?.finishAfterExit(preparation)
        } catch {
            await recordFailure(preparation, code: "launch-cleanup-failed")
            launchError = error.localizedDescription
        }
    }
}
