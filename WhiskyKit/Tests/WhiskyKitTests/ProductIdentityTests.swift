//
//  ProductIdentityTests.swift
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

final class ProductIdentityTests: XCTestCase {
    func testOpenBottleIdentityIsSeparateFromEveryWhiskySource() {
        XCTAssertEqual(ProductIdentity.name, "OpenBottle")
        XCTAssertEqual(ProductIdentity.appBundleIdentifier, "io.github.ewoudvv.OpenBottle")
        XCTAssertEqual(ProductIdentity.commandName, "openbottle")
        XCTAssertEqual(ProductIdentity.commandExecutable, "OpenBottleCmd")
        XCTAssertEqual(ProductIdentity.urlScheme, "openbottle")
        XCTAssertFalse(ProductIdentity.legacyBundleIdentifiers.contains(
            ProductIdentity.appBundleIdentifier
        ))
        XCTAssertEqual(ProductIdentity.repositoryURL?.absoluteString, "https://github.com/EwoudVV/OpenBottle")
    }
}
