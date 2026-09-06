//
//  SaveVaultPathIdentityTests.swift
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

final class SaveVaultPathIdentityTests: XCTestCase {
    func testReconstructedDirectoryURLVerifiesSnapshot() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "SaveVaultPathIdentityTests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let source = fixture.appending(path: "save.dat")
        try Data("progress".utf8).write(to: source)
        let vault = SaveVault(rootURL: fixture.appending(path: "vault"))
        let snapshot = try vault.capture(
            bottleID: "test-bottle",
            gameID: "test-game",
            sources: [SaveSource(id: "progress", url: source, kind: .file)],
            identifier: "snapshot"
        )
        let reconstructedURL = URL(
            fileURLWithPath: snapshot.url.path(percentEncoded: false),
            isDirectory: false
        )

        XCTAssertEqual(try vault.verify(snapshotAt: reconstructedURL), snapshot)
    }
}
