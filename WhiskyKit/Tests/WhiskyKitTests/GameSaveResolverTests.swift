//
//  GameSaveResolverTests.swift
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

@testable import WhiskyKit
import XCTest

final class GameSaveResolverTests: XCTestCase {
    func testEveryPortableRootResolvesInsideItsExpectedDirectory() throws {
        let bottle = URL(fileURLWithPath: "/tmp/OpenBottleTests/bottle")
        let install = URL(fileURLWithPath: "/tmp/OpenBottleTests/game")
        let context = GameSaveContext(
            bottleURL: bottle,
            gameInstallURL: install,
            wineUserName: "player"
        )
        let roots: [GameSaveRoot] = [
            .gameInstall,
            .wineUserProfile,
            .documents,
            .savedGames,
            .appDataRoaming,
            .appDataLocal,
            .appDataLocalLow
        ]
        let locations = roots.map {
            GameSaveLocation(
                id: $0.rawValue,
                root: $0,
                path: "Studio/Game/save.dat",
                kind: .file,
                required: true
            )
        }

        let resolved = try GameSaveResolver.resolve(locations, context: context)
        let profile = bottle.appending(path: "drive_c/users/player")
        let expectedRoots: [String: URL] = [
            GameSaveRoot.gameInstall.rawValue: install,
            GameSaveRoot.wineUserProfile.rawValue: profile,
            GameSaveRoot.documents.rawValue: profile.appending(path: "Documents"),
            GameSaveRoot.savedGames.rawValue: profile.appending(path: "Saved Games"),
            GameSaveRoot.appDataRoaming.rawValue: profile.appending(path: "AppData/Roaming"),
            GameSaveRoot.appDataLocal.rawValue: profile.appending(path: "AppData/Local"),
            GameSaveRoot.appDataLocalLow.rawValue: profile.appending(path: "AppData/LocalLow")
        ]

        XCTAssertEqual(resolved.count, roots.count)
        for (root, source) in zip(roots, resolved) {
            let expected = try XCTUnwrap(expectedRoots[root.rawValue])
                .appending(path: "Studio/Game/save.dat")
            XCTAssertEqual(source.id, root.rawValue)
            XCTAssertEqual(source.url.standardizedFileURL, expected.standardizedFileURL)
            XCTAssertEqual(source.kind, .file)
            XCTAssertTrue(source.required)
        }
    }

    func testDirectoryCannotReplaceAnEntirePortableRoot() {
        let bottle = URL(fileURLWithPath: "/tmp/OpenBottleTests/bottle")
        let install = URL(fileURLWithPath: "/tmp/OpenBottleTests/game")
        XCTAssertThrowsError(try GameSaveResolver.resolve(
            [GameSaveLocation(id: "whole-save", root: .gameInstall, path: "", kind: .directory)],
            context: GameSaveContext(bottleURL: bottle, gameInstallURL: install)
        )) { error in
            XCTAssertEqual(error as? GameSaveResolverError, .invalidRelativePath(""))
        }
    }

    func testContextDetectsTheBottleWineProfileName() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "GameSaveResolverTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(
            at: fixture.appending(path: "drive_c/users/player"),
            withIntermediateDirectories: true
        )

        let context = GameSaveContext(
            bottleURL: fixture,
            gameInstallURL: fixture.appending(path: "game")
        )

        XCTAssertEqual(context.wineUserName, "player")
    }

    func testUnsafeRelativePathsAreRejected() {
        let context = GameSaveContext(
            bottleURL: URL(fileURLWithPath: "/tmp/OpenBottleTests/bottle"),
            gameInstallURL: URL(fileURLWithPath: "/tmp/OpenBottleTests/game")
        )
        let paths = [
            "",
            "/absolute/save.dat",
            "../outside.dat",
            "folder/../outside.dat",
            "folder/./save.dat",
            "folder//save.dat",
            "folder\\save.dat"
        ]

        for path in paths {
            XCTAssertThrowsError(try GameSaveResolver.resolve(
                [GameSaveLocation(id: "save", root: .gameInstall, path: path, kind: .file)],
                context: context
            )) { error in
                XCTAssertEqual(error as? GameSaveResolverError, .invalidRelativePath(path))
            }
        }
    }

    func testDefaultDatabaseHasTheScrewDriversSavePlan() throws {
        let entry = try XCTUnwrap(GameDBLoader.loadDefaults().first { $0.id == "screw-drivers" })
        let locations = try XCTUnwrap(entry.saveLocations)

        XCTAssertEqual(entry.steamAppId, 1_279_510)
        XCTAssertEqual(locations.count, 15)
        XCTAssertEqual(Set(locations.map(\.id)), Set([
            "audio-settings",
            "building-platform",
            "car-categories",
            "cars",
            "character",
            "custom-maps",
            "ghosts",
            "graphs",
            "input-mappings",
            "inventory",
            "last-car",
            "progress",
            "settings",
            "workshop-showcase",
            "workshop-showcase-data"
        ]))
        XCTAssertTrue(locations.allSatisfy { $0.root == .gameInstall })
        XCTAssertTrue(locations.allSatisfy { !$0.required })
    }
}
