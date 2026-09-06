//
//  SteamClientOrchestrator+PreparedLaunch.swift
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
    func runPreparedLaunch(
        _ game: SteamGame,
        steamExe: URL,
        preparation: SteamLaunchPreparation?,
        offline: Bool,
        clientAlreadyRunning: Bool
    ) async {
        let libraryURL = preparation?.runtimeSelection.libraryURL
            ?? WhiskyWineInstaller.libraryFolder
        await RuntimeContext.withLibrary(libraryURL) {
            if clientAlreadyRunning {
                guard await ensureSteamClient(
                    steamExe,
                    preparation: preparation,
                    offline: offline
                )
                else { return }
                guard await requestLaunch(
                    game,
                    preparation: preparation,
                    offline: offline
                )
                else { return }
            } else {
                // A running Steam process launches the game with its own
                // environment, not the environment of a later -applaunch
                // helper. Send the profiled -applaunch first on a cold client
                // so Steam and its game inherit the same GameDB environment.
                guard await requestLaunch(
                    game,
                    preparation: preparation,
                    offline: offline
                )
                else { return }
                guard await observeColdClientStart(preparation: preparation) else { return }
            }
            guard await observeGameStart(game, preparation: preparation) else { return }
            await beginExitMonitoring(game, preparation: preparation)
        }
    }

    private func observeColdClientStart(
        preparation: SteamLaunchPreparation?
    ) async -> Bool {
        if await watch.waitForAny(of: ["steam.exe"], timeout: timing.clientReadyTimeout) {
            driver.clientDidBecomeReady()
            return await !recordCancellationIfNeeded(preparation)
        }
        let failureCode = Task.isCancelled ? "launch-cancelled" : "steam-client-start-failed"
        await recordFailure(preparation, code: failureCode)
        if !Task.isCancelled {
            launchError = SteamOrchestratorError.clientTimeout.errorDescription
        }
        return false
    }
}
