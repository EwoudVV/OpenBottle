//
//  RuntimeSlotManagerTests.swift
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

final class RuntimeSlotManagerTests: XCTestCase {
    func testInstallingAnUpdateRetainsAndVerifiesThePreviousSlot() throws {
        let fixture = try RuntimeSlotFixture()
        defer { fixture.remove() }
        let manager = RuntimeSlotManager(rootURL: fixture.root.appending(path: "Runtimes"))
        let firstArchive = try fixture.makeArchive(version: SemanticVersion(3, 1, 1), marker: "first")
        let first = try manager.install(
            tarball: firstArchive,
            channel: .stable,
            at: Date(timeIntervalSince1970: 100)
        )
        let secondArchive = try fixture.makeArchive(version: SemanticVersion(3, 2, 0), marker: "second")
        let second = try manager.install(
            tarball: secondArchive,
            channel: .stable,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(try manager.defaultSlot()?.id, second.id)
        XCTAssertEqual(try manager.slots().map(\.id), [second.id, first.id])
        XCTAssertNoThrow(try manager.verify(first))
        XCTAssertNoThrow(try manager.verify(second))
        XCTAssertTrue(first.manifest.capabilities.contains("dxvk"))
        XCTAssertTrue(first.manifest.capabilities.contains("dxmt"))
        XCTAssertEqual(first.manifest.components.first?.license, "LGPL-2.1-or-later")
    }

    func testChangedComponentFailsVerification() throws {
        let fixture = try RuntimeSlotFixture()
        defer { fixture.remove() }
        let manager = RuntimeSlotManager(rootURL: fixture.root.appending(path: "Runtimes"))
        let archive = try fixture.makeArchive(version: SemanticVersion(3, 1, 1), marker: "original")
        let slot = try manager.install(tarball: archive, channel: .stable)
        try Data("changed".utf8).write(to: slot.libraryURL.appending(path: "Wine/bin/wine64"))

        XCTAssertThrowsError(try manager.verify(slot)) { error in
            XCTAssertEqual(error as? RuntimeSlotError, .componentChanged("Wine"))
        }
    }

    @MainActor
    func testTaskLocalRuntimeChangesWinePathsForOnlyThatOperation() async throws {
        let before = Wine.wineBinary
        let selected = URL(fileURLWithPath: "/tmp/OpenBottle-Runtime/Libraries")

        await RuntimeContext.withLibrary(selected) {
            XCTAssertEqual(Wine.wineBinary, selected.appending(path: "Wine/bin/wine64"))
        }
        XCTAssertEqual(Wine.wineBinary, before)
    }
}

final class RuntimeSlotFixture {
    let root: URL
    private var archiveNumber = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RuntimeSlotManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeArchive(
        version: SemanticVersion,
        marker: String
    ) throws -> URL {
        archiveNumber += 1
        let source = root.appending(path: "source-\(archiveNumber)")
        let libraries = source.appending(path: "Libraries")
        let wine = libraries.appending(path: "Wine/bin/wine64")
        let dxvk = libraries.appending(path: "DXVK/x64/d3d11.dll")
        let dxmt = libraries.appending(path: "DXMT/x64/d3d11.dll")
        for file in [wine, dxvk, dxmt] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("\(marker)-\(file.lastPathComponent)".utf8).write(to: file)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wine.path
        )
        try writeVersion(version, to: libraries.appending(path: "WhiskyWineVersion.plist"))

        let archive = root.appending(path: "runtime-\(archiveNumber).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = source
        tar.arguments = ["-czf", archive.path, "Libraries"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }

    private func writeVersion(
        _ version: SemanticVersion,
        to url: URL
    ) throws {
        let plist: [String: Any] = [
            "version": ["major": version.major, "minor": version.minor, "patch": version.patch],
            "dxvkVersion": "1.10.3",
            "dxmtVersion": "0.80"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
