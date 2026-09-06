//
//  SaveSourcePlanStoreTests.swift
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

final class SaveSourcePlanStoreTests: XCTestCase {
    func testBottleRelativeSourceRebasesAfterBottleMoves() throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalBottle = root.appending(path: "Original")
        let movedBottle = root.appending(path: "Moved")
        let store = SaveSourcePlanStore(rootURL: root.appending(path: "plans"))
        let source = SaveSource(
            id: "progress",
            url: originalBottle.appending(path: "drive_c/save.dat"),
            kind: .file
        )

        let record = try store.save(
            sources: [source],
            bottleURL: originalBottle,
            bottleID: "test-bottle",
            gameID: "test-game",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let loaded = try store.load(
            bottleURL: movedBottle,
            bottleID: "test-bottle",
            gameID: "test-game"
        )

        XCTAssertEqual(record.sources.first?.location, .bottleRelative("drive_c/save.dat"))
        XCTAssertEqual(loaded.first?.url, movedBottle.appending(path: "drive_c/save.dat"))
        XCTAssertEqual(loaded.first?.kind, .file)
    }

    func testExternalSourceKeepsItsAbsoluteLocation() throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = root.appending(path: "Bottle")
        let external = root.appending(path: "External/save.dat")
        let store = SaveSourcePlanStore(rootURL: root.appending(path: "plans"))

        _ = try store.save(
            sources: [SaveSource(id: "external", url: external, kind: .file)],
            bottleURL: bottle,
            bottleID: "test-bottle",
            gameID: "test-game"
        )
        let loaded = try store.load(
            bottleURL: bottle,
            bottleID: "test-bottle",
            gameID: "test-game"
        )

        XCTAssertEqual(loaded.first?.url, external)
    }

    private func makeFixture() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SaveSourcePlanStoreTests-\(UUID().uuidString)")
    }
}
