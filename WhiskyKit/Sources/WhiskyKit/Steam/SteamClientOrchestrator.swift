//
//  SteamClientOrchestrator.swift
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

import Combine
import Foundation

public enum SteamOrchestratorError: LocalizedError, Equatable {
    /// steam.exe did not appear in the process list within the ready timeout.
    case clientTimeout
    /// The bottle no longer contains a Steam installation.
    case steamNotInstalled

    public var errorDescription: String? {
        switch self {
        case .clientTimeout:
            String(localized: "steam.client.timeout")
        case .steamNotInstalled:
            String(localized: "steam.client.missing")
        }
    }
}

/// Runs Steam games through the Windows Steam client without making the user
/// look at it: ensures the client is up (silently), fires `-applaunch`, and
/// watches for the game process to actually appear.
///
/// The side effects go through a ``SteamClientDriver``; this type owns the
/// sequencing. Three pieces of it are the reason it lives in the kit:
///
/// - **Single-flight client startup.** Concurrent launches await one startup
///   attempt instead of each racing to start their own client.
/// - **Per-game phases.** The launch grace period runs for up to two minutes,
///   and starting a second game while the first precompiles shaders is normal.
/// - **One short-lived process snapshot.** The launch watch polls every 2s and
///   the status poller every 10s; sharing a snapshot stops them each running
///   their own `tasklist.exe`, and concurrent reads coalesce into one.
@MainActor
public final class SteamClientOrchestrator: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case startingClient
        case launching
    }

    /// The waits and intervals, injectable so tests do not sit through them.
    public struct Timing: Sendable {
        /// How long to wait for steam.exe after starting the client.
        public var clientReadyTimeout: TimeInterval = 90
        /// A cold profiled launch starts Steam and the game in one process. Its
        /// first startup can take longer than bringing up the client alone.
        public var coldClientReadyTimeout: TimeInterval = 150
        /// Steam forks the game and the -applaunch invocation returns
        /// immediately; shader precompilation can hold the real game process
        /// back for a long time. Lutris ships 120 seconds for this same wait.
        public var launchGrace: TimeInterval = 120
        /// How often a wait re-reads the process list.
        public var pollInterval: Duration = .seconds(2)
        /// How often running-state tracking re-reads the process list.
        public var trackingInterval: Duration = .seconds(10)
        /// How long one process snapshot answers for.
        public var snapshotLifetime: TimeInterval = 1

        public init(
            clientReadyTimeout: TimeInterval = 90,
            coldClientReadyTimeout: TimeInterval = 150,
            launchGrace: TimeInterval = 120,
            pollInterval: Duration = .seconds(2),
            trackingInterval: Duration = .seconds(10),
            snapshotLifetime: TimeInterval = 1
        ) {
            self.clientReadyTimeout = clientReadyTimeout
            self.coldClientReadyTimeout = coldClientReadyTimeout
            self.launchGrace = launchGrace
            self.pollInterval = pollInterval
            self.trackingInterval = trackingInterval
            self.snapshotLifetime = snapshotLifetime
        }
    }

    /// Where each in-flight launch is, keyed by App ID.
    @Published public private(set) var phases: [Int: Phase] = [:]
    /// App IDs whose executables are currently in the bottle's process list.
    @Published public private(set) var runningAppIds: Set<Int> = []
    @Published public var launchError: String?

    let bottle: Bottle
    let driver: SteamClientDriver
    let timing: Timing
    let launchSafety: SteamLaunchSafetyController?

    private var trackingTask: Task<Void, Never>?
    private var executableNamesByAppId: [Int: Set<String>] = [:]
    /// The in-flight client startup, shared by every concurrent launch.
    private var clientStartup: Task<Void, Error>?
    private var launchTasks: [Int: Task<Void, Never>] = [:]
    var launchTransactionIDs: [Int: UUID] = [:]
    var exitMonitorTasks: [UUID: Task<Void, Never>] = [:]
    var processSnapshot: (processes: [WineProcess], taken: Date)?
    var snapshotRead: Task<[WineProcess], Never>?

    lazy var watch = SteamProcessWatch(pollInterval: timing.pollInterval) { [weak self] in
        await self?.runningImageNames() ?? []
    }

    /// - Parameters:
    ///   - bottle: The bottle whose Steam client this drives.
    ///   - driver: The side-effect boundary; defaults to Wine.
    ///   - timing: Waits and intervals; defaults are the production values.
    public init(
        bottle: Bottle,
        driver: SteamClientDriver? = nil,
        timing: Timing = Timing(),
        launchSafety: SteamLaunchSafetyController? = nil
    ) {
        self.bottle = bottle
        self.driver = driver ?? WineSteamClientDriver(bottle: bottle)
        self.timing = timing
        self.launchSafety = launchSafety
    }

    /// Launches a game via `-applaunch`, bringing the client up first if needed.
    ///
    /// Owns the task rather than the caller so ``stop()`` can cancel a launch
    /// still inside its grace period.
    public func launch(_ game: SteamGame) {
        guard phases[game.appId] == nil else { return }
        phases[game.appId] = .startingClient
        launchTasks[game.appId] = Task { await performLaunch(game) }
    }

    /// Polls the bottle's process list so the library can show which games
    /// are running, including ones started outside Whisky.
    public func startTracking(games: [SteamGame]) {
        trackingTask?.cancel()
        for game in games where executableNamesByAppId[game.appId] == nil {
            executableNamesByAppId[game.appId] = SteamLibrary.executableNames(under: game.installURL)
        }
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRunningState()
                guard let interval = self?.timing.trackingInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Asks the game's processes to close, then refreshes the running state.
    public func stop(_ game: SteamGame) async {
        let names = executableNamesByAppId[game.appId]
            ?? SteamLibrary.executableNames(under: game.installURL)

        for process in await runningProcesses()
            where names.contains(process.imageName.lowercased()) {
            await driver.killProcess(winePID: process.winePID)
        }
        processSnapshot = nil
        await refreshRunningState()
    }

    /// Stops process tracking, cancels in-flight launches, and lets the driver
    /// release anything the ready hook started. Call when the owning view
    /// disappears.
    public func stop() {
        trackingTask?.cancel()
        trackingTask = nil
        for task in launchTasks.values {
            task.cancel()
        }
        launchTasks.removeAll()
        for task in exitMonitorTasks.values {
            task.cancel()
        }
        exitMonitorTasks.removeAll()
        clientStartup?.cancel()
        clientStartup = nil
        driver.shutdown()
    }

    // MARK: - Launch sequence

    private func performLaunch(_ game: SteamGame) async {
        defer {
            phases[game.appId] = nil
            launchTasks[game.appId] = nil
            launchTransactionIDs[game.appId] = nil
        }

        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            launchError = SteamOrchestratorError.steamNotInstalled.errorDescription
            return
        }
        let steamExe = steamRoot.appending(path: "steam.exe")
        let preparation: SteamLaunchPreparation?
        let transactionID = launchSafety == nil ? nil : UUID()
        launchTransactionIDs[game.appId] = transactionID
        guard let offline = await resolvedOfflinePolicy(for: game) else { return }

        let clientAlreadyRunning = await isClientRunning()
        if !clientAlreadyRunning, Self.shouldApplyLauncherFixes(settings: bottle.settings) {
            driver.applyLauncherFixes()
        }

        do {
            preparation = try await launchSafety?.prepare(
                game: game,
                bottleURL: bottle.url,
                identifier: transactionID ?? UUID()
            )
            if let preparation {
                guard await passesPreflight(game, preparation: preparation) else { return }
                _ = try await launchSafety?.markPrepared(preparation)
            }
        } catch {
            if !Task.isCancelled {
                launchError = error.localizedDescription
            }
            return
        }
        if await recordCancellationIfNeeded(preparation) { return }

        await runPreparedLaunch(
            game,
            steamExe: steamExe,
            preparation: preparation,
            offline: offline,
            clientAlreadyRunning: clientAlreadyRunning
        )
    }

    func ensureSteamClient(
        _ steamExe: URL,
        preparation: SteamLaunchPreparation?,
        offline: Bool
    ) async -> Bool {
        do {
            try await ensureClientRunning(steamExe: steamExe, offline: offline)
        } catch {
            let failureCode = Task.isCancelled ? "launch-cancelled" : "steam-client-start-failed"
            await recordFailure(preparation, code: failureCode)
            if !Task.isCancelled {
                launchError = error.localizedDescription
            }
            return false
        }
        return await !recordCancellationIfNeeded(preparation)
    }

    func requestLaunch(
        _ game: SteamGame,
        preparation: SteamLaunchPreparation?,
        offline: Bool
    ) async -> Bool {
        phases[game.appId] = .launching
        do {
            if let preparation {
                _ = try await launchSafety?.markLaunchRequested(preparation)
            }
            if await recordCancellationIfNeeded(preparation) { return false }
            try await driver.launchGame(game, offline: offline)
            return true
        } catch {
            await recordFailure(preparation, code: "game-launch-request-failed")
            launchError = error.localizedDescription
            return false
        }
    }

    func observeGameStart(
        _ game: SteamGame,
        preparation: SteamLaunchPreparation?
    ) async -> Bool {
        guard await waitForGameProcess(installURL: game.installURL) else {
            let failureCode = Task.isCancelled ? "launch-cancelled" : "game-process-timeout"
            await recordFailure(preparation, code: failureCode)
            if !Task.isCancelled {
                launchError = String(localized: "steam.launch.timeout")
            }
            return false
        }
        return await !recordCancellationIfNeeded(preparation)
    }

    private func ensureClientRunning(steamExe: URL, offline: Bool) async throws {
        if let clientStartup {
            return try await clientStartup.value
        }
        let startup = Task { try await startClient(steamExe: steamExe, offline: offline) }
        clientStartup = startup
        defer { clientStartup = nil }
        try await startup.value
    }

    private func startClient(steamExe: URL, offline: Bool) async throws {
        if await isClientRunning() {
            driver.clientDidBecomeReady()
            return
        }

        driver.startClient(steamExe: steamExe, offline: offline)

        if await watch.waitForAny(of: ["steam.exe"], timeout: timing.clientReadyTimeout) {
            driver.clientDidBecomeReady()
            return
        }
        throw SteamOrchestratorError.clientTimeout
    }

    private func isClientRunning() async -> Bool {
        await runningImageNames().contains("steam.exe")
    }

    /// Waits for any of the game's executables to appear in the process list.
    ///
    /// Returns `true` when the game shows up (or when no candidate exe names
    /// could be determined, in which case there is nothing to watch for).
    private func waitForGameProcess(installURL: URL) async -> Bool {
        let candidates = SteamLibrary.executableNames(under: installURL)
        return await watch.waitForAny(of: candidates, timeout: timing.launchGrace)
    }

    private func refreshRunningState() async {
        runningAppIds = await watch.runningKeys(byExecutables: executableNamesByAppId)
    }
}

// MARK: - Process snapshot

extension SteamClientOrchestrator {
    func runningImageNames() async -> Set<String> {
        guard await driver.hostWineImageNames().isEmpty == false else { return [] }
        return await Set(runningProcesses().map { $0.imageName.lowercased() })
    }

    /// One process list per ``Timing/snapshotLifetime``, and one read at a
    /// time: a caller arriving while a read is in flight awaits that read.
    func runningProcesses() async -> [WineProcess] {
        if let processSnapshot, Date().timeIntervalSince(processSnapshot.taken) < timing.snapshotLifetime {
            return processSnapshot.processes
        }
        if let snapshotRead {
            return await snapshotRead.value
        }

        let read = Task { await driver.processList() }
        snapshotRead = read
        let processes = await read.value
        snapshotRead = nil
        processSnapshot = (processes, Date())
        return processes
    }
}
