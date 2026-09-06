//
//  SafeProgramLauncher.swift
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

/// A launched program plus the cleanup task that follows its real process lifetime.
public struct SafeProgramSession: Sendable {
    public let result: Wine.ProgramRunResult
    private let completion: Task<LaunchTransactionRecord, Error>

    init(
        result: Wine.ProgramRunResult,
        completion: Task<LaunchTransactionRecord, Error>
    ) {
        self.result = result
        self.completion = completion
    }

    @discardableResult
    public func waitForExit() async throws -> LaunchTransactionRecord {
        try await completion.value
    }
}

/// Starts a direct executable through the shared save, profile, and rollback transaction.
public enum SafeProgramLauncher {
    public struct Timing: Sendable {
        public var startTimeout: TimeInterval
        public var pollInterval: Duration
        public var absentChecks: Int

        public init(
            startTimeout: TimeInterval = 8,
            pollInterval: Duration = .seconds(1),
            absentChecks: Int = 2
        ) {
            self.startTimeout = max(0, startTimeout)
            self.pollInterval = pollInterval
            self.absentChecks = max(1, absentChecks)
        }
    }

    @MainActor
    public static func launch(
        at url: URL,
        args: [String] = [],
        bottle: Bottle,
        environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil,
        programSettings: ProgramSettings? = nil,
        controller: LaunchSafetyController = .live(),
        entries: [GameDBEntry] = GameDBLoader.loadDefaults(),
        timing: Timing = Timing()
    ) async throws -> SafeProgramSession {
        let plan = try ProgramLaunchPlanner.resolve(
            programURL: url,
            bottleURL: bottle.url,
            userOverrides: programOverrides,
            appliedConfiguration: GameConfigSnapshot.load(from: bottle.url),
            entries: entries
        )
        let preparation = try await controller.begin(
            bottleURL: bottle.url,
            gameID: plan.gameID,
            saveSources: plan.saveSources
        )

        do {
            _ = try await controller.prepareConfiguration(preparation)
            _ = try await controller.markLaunchRequested(preparation)
            let result = try await Wine.runProgram(
                at: url,
                args: args,
                bottle: bottle,
                environment: environment,
                programOverrides: plan.launchPlan.overrides,
                programSettings: programSettings,
                gameProfileEnvironment: plan.launchPlan.gameProfileEnvironment
            )
            if result.exitCode != 0 {
                let record = try await finishFailure(
                    preparation,
                    controller: controller,
                    code: "program-launch-failed"
                )
                return SafeProgramSession(result: result, completion: Task { record })
            }
            return SafeProgramSession(
                result: result,
                completion: monitor(
                    processNames: plan.processNames,
                    bottle: bottle,
                    preparation: preparation,
                    controller: controller,
                    timing: timing
                )
            )
        } catch {
            _ = try? await finishFailure(
                preparation,
                controller: controller,
                code: "program-launch-failed"
            )
            throw error
        }
    }

    /// Runs a batch file through the same transaction and waits for `cmd` to finish.
    @MainActor
    @discardableResult
    public static func runBatchFile(
        at url: URL,
        bottle: Bottle,
        controller: LaunchSafetyController = .live(),
        entries: [GameDBEntry] = GameDBLoader.loadDefaults()
    ) async throws -> LaunchTransactionRecord {
        let plan = try ProgramLaunchPlanner.resolve(
            programURL: url,
            bottleURL: bottle.url,
            appliedConfiguration: GameConfigSnapshot.load(from: bottle.url),
            entries: entries
        )
        let preparation = try await controller.begin(
            bottleURL: bottle.url,
            gameID: plan.gameID,
            saveSources: plan.saveSources
        )
        do {
            _ = try await controller.prepareConfiguration(preparation)
            _ = try await controller.markLaunchRequested(preparation)
            _ = try await Wine.runBatchFile(url: url, bottle: bottle)
            _ = try await controller.markMonitoring(preparation)
            return try await controller.finish(preparation)
        } catch {
            _ = try? await finishFailure(
                preparation,
                controller: controller,
                code: "batch-launch-failed"
            )
            throw error
        }
    }

    @MainActor
    private static func monitor(
        processNames: Set<String>,
        bottle: Bottle,
        preparation: LaunchSafetyPreparation,
        controller: LaunchSafetyController,
        timing: Timing
    ) -> Task<LaunchTransactionRecord, Error> {
        let driver = WineSteamClientDriver(bottle: bottle)
        let watch = SteamProcessWatch(pollInterval: timing.pollInterval) {
            let hostNames = await driver.hostWineImageNames()
            guard !hostNames.isDisjoint(with: processNames) else { return [] }
            return await Set(driver.processList().map { $0.imageName.lowercased() })
        }
        return Task { @MainActor in
            let appeared = await watch.waitForAny(
                of: processNames,
                timeout: timing.startTimeout
            )
            if appeared {
                _ = try await controller.markMonitoring(preparation)
                let exited = await watch.waitUntilNone(
                    of: processNames,
                    consecutiveChecks: timing.absentChecks
                )
                if !exited {
                    return try await finishFailure(
                        preparation,
                        controller: controller,
                        code: "program-monitor-cancelled"
                    )
                }
            }
            return try await controller.finish(preparation)
        }
    }

    @MainActor
    private static func finishFailure(
        _ preparation: LaunchSafetyPreparation,
        controller: LaunchSafetyController,
        code: String
    ) async throws -> LaunchTransactionRecord {
        _ = try await controller.fail(preparation, code: code)
        return try await controller.finish(preparation)
    }
}
