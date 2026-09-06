//
//  DistributionIdentityTests.swift
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

final class DistributionIdentityTests: XCTestCase {
    func testOpenBottleEndpoints() {
        XCTAssertEqual(DistributionConfig.baseURL, "https://ewoudvv.github.io/OpenBottle")
        XCTAssertEqual(
            DistributionConfig.releasesBaseURL,
            "https://github.com/EwoudVV/OpenBottle/releases/download"
        )
        XCTAssertEqual(DistributionConfig.appcastURL, "https://ewoudvv.github.io/OpenBottle/appcast.xml")
        XCTAssertTrue(DistributionConfig.baseURL.hasPrefix("https://"))
        XCTAssertTrue(URL(string: DistributionConfig.appcastURL) != nil)
    }

    func testRuntimeDistributionIsExplicitlyUpstream() {
        XCTAssertEqual(DistributionConfig.runtimeBaseURL, "https://frankea.github.io/Whisky")
        XCTAssertEqual(
            DistributionConfig.runtimeReleasesBaseURL,
            "https://github.com/frankea/Whisky/releases/download"
        )
        XCTAssertFalse(DistributionConfig.appUpdatesEnabled)
    }
}
