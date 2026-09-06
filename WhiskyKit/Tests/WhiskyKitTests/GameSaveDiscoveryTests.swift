//
//  GameSaveDiscoveryTests.swift
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

final class GameSaveDiscoveryTests: XCTestCase {
    func testProgramDiscoveryFindsMatchingProfileFolderAndIgnoresNoise() throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appending(path: "drive_c/Games/Example/example.exe")
        let matching = root.appending(path: "drive_c/users/test/AppData/LocalLow/Studio/Example Game")
        let unrelated = root.appending(path: "drive_c/users/test/AppData/LocalLow/Other/Unrelated")
        try FileManager.default.createDirectory(
            at: program.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: matching, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data().write(to: program)
        try Data("save".utf8).write(to: matching.appending(path: "slot.dat"))
        try Data("noise".utf8).write(to: unrelated.appending(path: "slot.dat"))
        let entry = GameDBEntry(
            id: "example-game",
            title: "Example Game",
            rating: .unverified,
            exeNames: ["example.exe"],
            variants: []
        )

        let sources = GameSaveDiscovery.programSources(
            programURL: program,
            bottleURL: root,
            entry: entry,
            wineUserName: "test"
        )

        XCTAssertEqual(
            sources.map { $0.url.resolvingSymlinksInPath() },
            [matching.resolvingSymlinksInPath()]
        )
        XCTAssertTrue(sources.allSatisfy { $0.id.hasPrefix("discovered-") })
        XCTAssertFalse(sources[0].id.lowercased().contains("example"))
    }

    func testDeclaredSourceWinsOverAnOverlappingDiscovery() {
        let root = URL(fileURLWithPath: "/tmp/bottle")
        let declared = SaveSource(
            id: "declared",
            url: root.appending(path: "saves"),
            kind: .directory
        )
        let discovered = SaveSource(
            id: "discovered-1234",
            url: root.appending(path: "saves/profile"),
            kind: .directory
        )

        XCTAssertEqual(
            GameSaveDiscovery.merging(declared: [declared], discovered: [discovered]),
            [declared]
        )
    }

    private func makeFixture() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "GameSaveDiscoveryTests-\(UUID().uuidString)")
    }
}
