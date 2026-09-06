//
//  GameSavePolicyTests.swift
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

final class GameSavePolicyTests: XCTestCase {
    func testMissingPolicyDefaultsToLocalOnlyAndChoicePersists() async throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameSavePolicyStore(rootURL: root)

        let initial = try await store.policy(
            bottleID: "test-bottle",
            gameID: "steam-42"
        )
        XCTAssertEqual(initial, .localOnly)

        let written = try await store.setPolicy(
            .cloudAllowed,
            bottleID: "test-bottle",
            gameID: "steam-42",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(written.policy, .cloudAllowed)
        let reloaded = try await GameSavePolicyStore(rootURL: root).policy(
            bottleID: "test-bottle",
            gameID: "steam-42"
        )
        XCTAssertEqual(reloaded, .cloudAllowed)
    }

    func testCorruptPolicyFailsClosed() async throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "test-bottle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appending(path: "steam-42.json"))

        do {
            _ = try await GameSavePolicyStore(rootURL: root).policy(
                bottleID: "test-bottle",
                gameID: "steam-42"
            )
            XCTFail("Expected a damaged policy to be rejected")
        } catch {
            XCTAssertEqual(error as? GameSavePolicyError, .invalidRecord)
        }
    }

    private func makeFixture() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "GameSavePolicyTests-\(UUID().uuidString)")
    }
}
