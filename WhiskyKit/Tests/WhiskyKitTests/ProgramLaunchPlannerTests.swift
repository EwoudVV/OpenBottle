//
//  ProgramLaunchPlannerTests.swift
//  WhiskyKitTests
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
@testable import WhiskyKit
import XCTest

final class ProgramLaunchPlannerTests: XCTestCase {
    func testKnownExecutableGetsProfileAndSavePlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ProgramLaunchPlannerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appending(path: "drive_c/Games/Example")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let executable = install.appending(path: "example.exe")
        try Data("portable executable".utf8).write(to: executable)
        let entry = GameDBEntry(
            id: "example-game",
            title: "Example Game",
            rating: .playable,
            exeNames: ["example.exe"],
            saveLocations: [
                GameSaveLocation(
                    id: "progress",
                    root: .gameInstall,
                    path: "save.dat",
                    kind: .file
                )
            ],
            variants: [
                GameConfigVariant(
                    id: "safe",
                    label: "Safe",
                    isDefault: true,
                    settings: GameConfigVariantSettings(graphicsBackend: .dxmt)
                )
            ]
        )

        let plan = try ProgramLaunchPlanner.resolve(
            programURL: executable,
            bottleURL: root,
            entries: [entry]
        )

        XCTAssertEqual(plan.gameID, "example-game")
        XCTAssertEqual(plan.saveSources.map(\.url), [install.appending(path: "save.dat")])
        XCTAssertEqual(plan.launchPlan.overrides.graphicsBackend, GraphicsBackend.dxmt)
        XCTAssertFalse(plan.launchPlan.provenance.isEmpty)
        XCTAssertEqual(plan.processNames, ["example.exe"])
    }

    func testFallbackIdentityIsStableOpaqueAndPathSensitive() {
        let bottle = URL(fileURLWithPath: "/Users/player/OpenBottle/Test")
        let first = bottle.appending(path: "drive_c/Games/One/game.exe")
        let equivalent = bottle.appending(path: "drive_c/Games/One/folder/../game.exe")
        let second = bottle.appending(path: "drive_c/Games/Two/game.exe")
        let identifier = ProgramLaunchPlanner.fallbackGameID(
            programURL: first,
            bottleURL: bottle
        )

        XCTAssertEqual(
            identifier,
            ProgramLaunchPlanner.fallbackGameID(
                programURL: equivalent,
                bottleURL: bottle
            )
        )
        XCTAssertFalse(identifier == ProgramLaunchPlanner.fallbackGameID(
            programURL: second,
            bottleURL: bottle
        ))
        XCTAssertTrue(identifier.hasPrefix("program-"))
        XCTAssertFalse(identifier.contains("player"))
        XCTAssertFalse(identifier.contains("game.exe"))
    }
}
