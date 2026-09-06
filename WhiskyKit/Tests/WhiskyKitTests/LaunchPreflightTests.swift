//
//  LaunchPreflightTests.swift
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

@MainActor
final class LaunchPreflightTests: XCTestCase {
    func testValidRuntimeAndOrdinaryX64ProgramCanLaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = await LaunchPreflight.evaluate(fixture.input())

        XCTAssertTrue(report.canLaunch)
        XCTAssertEqual(report.resolvedBackend, .wined3d)
    }

    func testMissingRuntimeAndRosettaAreBothActionableBlockers() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = fixture.root.appending(path: "missing-runtime")
        let input = fixture.input(
            runtimeURL: missing,
            isAppleSilicon: true,
            isRosettaInstalled: false
        )

        let report = await LaunchPreflight.evaluate(input)

        XCTAssertFalse(report.canLaunch)
        XCTAssertTrue(report.findings.contains { $0.id == "runtime-missing" })
        XCTAssertTrue(report.findings.contains { $0.id == "rosetta-missing" })
        XCTAssertTrue(report.findings.allSatisfy {
            $0.severity != .blocked || $0.nextAction != nil
        })
    }

    func testWindowsArmExecutableIsRejectedBeforeWineStarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var armExecutable = PEBuilder.createMinimalPE32Plus()
        armExecutable[0x84] = 0x64
        armExecutable[0x85] = 0xAA
        try armExecutable.write(to: fixture.program)

        let report = await LaunchPreflight.evaluate(fixture.input())

        XCTAssertFalse(report.canLaunch)
        XCTAssertTrue(report.findings.contains { $0.id == "windows-arm64" })
    }

    func testKernelAntiCheatBlocksButUserSpaceMarkerOnlyWarns() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.install.appending(path: "EasyAntiCheat_EOS.exe"))

        let warning = await LaunchPreflight.evaluate(fixture.input())

        XCTAssertTrue(warning.canLaunch)
        XCTAssertTrue(warning.findings.contains { $0.id == "anticheat-warning" })

        try Data().write(to: fixture.install.appending(path: "EasyAntiCheat_EOS.sys"))
        let blocked = await LaunchPreflight.evaluate(fixture.input())

        XCTAssertFalse(blocked.canLaunch)
        XCTAssertTrue(blocked.findings.contains { $0.id.hasPrefix("kernel-driver-") })
    }

    private func makeFixture() throws -> PreflightFixture {
        try PreflightFixture()
    }
}

private struct PreflightFixture {
    let root: URL
    let bottle: URL
    let install: URL
    let program: URL
    let runtime: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchPreflightTests-\(UUID().uuidString)")
        bottle = root.appending(path: "bottle")
        install = bottle.appending(path: "drive_c/Game")
        program = install.appending(path: "game.exe")
        runtime = root.appending(path: "runtime/Libraries")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try PEBuilder.createMinimalPE32Plus().write(to: program)
        let wine = runtime.appending(path: "Wine/bin/wine64")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("wine".utf8).write(to: wine)
        let plist: [String: Any] = [
            "version": ["major": 3, "minor": 1, "patch": 1]
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: runtime.appending(path: "WhiskyWineVersion.plist"))
    }

    func input(
        runtimeURL: URL? = nil,
        isAppleSilicon: Bool = false,
        isRosettaInstalled: Bool = true
    ) -> LaunchPreflightInput {
        let selectedRuntime = runtimeURL ?? runtime
        return LaunchPreflightInput(
            bottleURL: bottle,
            programURL: program,
            installURL: install,
            entry: nil,
            launcher: nil,
            backend: .wined3d,
            runtime: RuntimeSelection(
                slotID: nil,
                libraryURL: selectedRuntime,
                manifest: nil,
                reason: "test"
            ),
            isAppleSilicon: isAppleSilicon,
            isRosettaInstalled: isRosettaInstalled,
            macOSVersion: MacOSVersion(major: 15, minor: 0, patch: 0)
        )
    }
}
