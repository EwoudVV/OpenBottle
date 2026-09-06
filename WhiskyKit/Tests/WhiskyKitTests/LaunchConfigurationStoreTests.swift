//
//  LaunchConfigurationStoreTests.swift
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

final class LaunchConfigurationStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let bottle: URL
        let metadata: URL
        let d3d11: URL
    }

    func testRestoreRevertsManagedFilesAndKeepsRunHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let bottleID = BottleLaunchIdentity.id(for: fixture.bottle)
        let vault = SaveVault(rootURL: fixture.root.appending(path: "configuration-vault"))
        let journal = SaveRestoreJournal(rootURL: fixture.root.appending(path: "restore-journal"))
        let store = LaunchConfigurationStore(vault: vault, restoreJournal: journal)
        let snapshot = try store.capture(
            bottleURL: fixture.bottle,
            bottleID: bottleID,
            gameID: "test-game",
            identifier: operationID
        )

        try Data("temporary-settings".utf8).write(to: fixture.metadata)
        try Data("dxmt".utf8).write(to: fixture.d3d11)
        let newDXGI = fixture.d3d11.deletingLastPathComponent().appending(path: "dxgi.dll")
        try Data("new-dxgi".utf8).write(to: newDXGI)
        let history = fixture.bottle.appending(path: "Program Settings/game.run-history.plist")
        try FileManager.default.createDirectory(
            at: history.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep-history".utf8).write(to: history)

        try await store.restore(
            bottleURL: fixture.bottle,
            bottleID: bottleID,
            gameID: "test-game",
            snapshotID: snapshot.manifest.id,
            operationID: operationID
        )

        XCTAssertEqual(try Data(contentsOf: fixture.metadata), Data("baseline-settings".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.d3d11), Data("wined3d".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDXGI.path))
        XCTAssertEqual(try Data(contentsOf: history), Data("keep-history".utf8))
        let restoreRecord = try await journal.record(for: operationID)
        XCTAssertEqual(restoreRecord.stage, .completed)
    }

    func testSourcePlanHasUniqueStableIDs() throws {
        let bottle = URL(fileURLWithPath: "/tmp/OpenBottle-Test")
        let sources = LaunchConfigurationStore.sources(for: bottle)

        XCTAssertEqual(sources.count, 56)
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
        XCTAssertTrue(sources.contains { $0.id == "system32-d3d11-dll" })
        XCTAssertTrue(sources.contains { $0.id == "syswow64-dxgi-dll-original" })
        XCTAssertTrue(sources.contains { $0.id == "nvngx-model-config" })
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchConfigurationStoreTests-\(UUID().uuidString)")
        let bottle = root.appending(path: "bottle")
        let system32 = bottle.appending(path: "drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let metadata = bottle.appending(path: "Metadata.plist")
        let d3d11 = system32.appending(path: "d3d11.dll")
        try Data("baseline-settings".utf8).write(to: metadata)
        try Data("wined3d".utf8).write(to: d3d11)
        return Fixture(root: root, bottle: bottle, metadata: metadata, d3d11: d3d11)
    }
}
