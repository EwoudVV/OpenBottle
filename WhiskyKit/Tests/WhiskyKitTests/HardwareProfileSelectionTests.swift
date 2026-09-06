//
//  HardwareProfileSelectionTests.swift
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

final class HardwareProfileSelectionTests: XCTestCase {
    func testMeasuredM1MaxProfileOnlyWinsOnItsTestedHardware() throws {
        let entry = try XCTUnwrap(
            GameDBLoader.loadDefaults().first { $0.id == "screw-drivers" }
        )
        let metadata = ProgramMetadata(exeName: "Screw Drivers.exe", steamAppId: 1_279_510)
        let testedMac = HardwareProfile(
            modelIdentifier: "MacBookPro18,2",
            chipName: "Apple M1 Max",
            gpuName: "Apple M1 Max",
            memoryGB: 64,
            displayWidth: 3_456,
            displayHeight: 2_234,
            refreshRate: 120,
            macOSVersion: "26.5.2",
            cpuArchitecture: "arm64"
        )
        let otherMac = HardwareProfile(
            modelIdentifier: "Mac14,5",
            chipName: "Apple M2 Max",
            gpuName: "Apple M2 Max",
            memoryGB: 32,
            displayWidth: 3_024,
            displayHeight: 1_964,
            refreshRate: 120,
            macOSVersion: "26.5.2",
            cpuArchitecture: "arm64"
        )

        let testedMatch = GameMatcher.bestMatch(
            metadata: metadata,
            against: [entry],
            hardwareProfile: testedMac
        )
        let otherMatch = GameMatcher.bestMatch(
            metadata: metadata,
            against: [entry],
            hardwareProfile: otherMac
        )

        XCTAssertEqual(testedMatch?.recommendedVariant?.id, "dxmt-metalfx-2x-experimental")
        XCTAssertEqual(otherMatch?.recommendedVariant?.id, "dxvk-balanced-60")
    }

    func testConstraintDecodeKeepsHardwareFields() throws {
        let entry = try XCTUnwrap(
            GameDBLoader.loadDefaults().first { $0.id == "screw-drivers" }
        )
        let variant = try XCTUnwrap(
            entry.variants.first { $0.id == "dxmt-metalfx-2x-experimental" }
        )

        XCTAssertEqual(variant.constraints?.macModels, ["MacBookPro18,2"])
        XCTAssertEqual(variant.constraints?.minimumMemoryGB, 64)
        XCTAssertEqual(variant.testedWith?.displayWidth, 3_456)
        XCTAssertEqual(variant.testedWith?.refreshRate, 120)
    }
}
