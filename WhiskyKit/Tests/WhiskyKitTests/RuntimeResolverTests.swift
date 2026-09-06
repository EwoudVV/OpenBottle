//
//  RuntimeResolverTests.swift
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
import SemanticVersion
@testable import WhiskyKit
import XCTest

final class RuntimeResolverTests: XCTestCase {
    func testSuccessfulSelectionBecomesTheGamePin() throws {
        let fixture = try RuntimeSlotFixture()
        defer { fixture.remove() }
        let manager = RuntimeSlotManager(rootURL: fixture.root.appending(path: "Runtimes"))
        let first = try manager.install(
            tarball: fixture.makeArchive(version: SemanticVersion(3, 1, 1), marker: "first"),
            channel: .stable,
            at: Date(timeIntervalSince1970: 100)
        )
        _ = try manager.install(
            tarball: fixture.makeArchive(version: SemanticVersion(3, 2, 0), marker: "second"),
            channel: .stable,
            at: Date(timeIntervalSince1970: 200)
        )
        let resolver = RuntimeResolver(
            manager: manager,
            pins: RuntimePinStore(rootURL: fixture.root.appending(path: "Pins")),
            legacyLibraryURL: fixture.root.appending(path: "Legacy")
        )
        let firstSelection = try resolver.resolve(slotID: first.id)
        try resolver.recordSuccess(
            firstSelection,
            bottleID: "test-bottle",
            gameID: "test-game"
        )

        let resolved = try resolver.resolve(bottleID: "test-bottle", gameID: "test-game")

        XCTAssertEqual(resolved.slotID, first.id)
        XCTAssertEqual(resolved.reason, "last successful launch")
    }
}
