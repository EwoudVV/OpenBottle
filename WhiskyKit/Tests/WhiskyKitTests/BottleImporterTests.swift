//
//  BottleImporterTests.swift
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

final class BottleImporterTests: XCTestCase {
    func testCopyPublishesVerifiedBottleAndLeavesSourceUnchanged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appending(path: "Whisky/Bottle")
        let destinationRoot = fixture.appending(path: "OpenBottle/Bottles")
        try makeBottle(at: source)
        let metadata = source.appending(path: "Metadata.plist")
        let sourceMetadata = try Data(contentsOf: metadata)
        let identifier = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let result = try BottleImporter.copy(
            bottleAt: source,
            to: destinationRoot,
            identifier: identifier
        )

        XCTAssertEqual(result.sourceURL, source.standardizedFileURL)
        XCTAssertEqual(result.bottleURL.lastPathComponent, identifier.uuidString)
        XCTAssertEqual(try Data(contentsOf: metadata), sourceMetadata)
        XCTAssertEqual(
            try Data(contentsOf: result.bottleURL.appending(path: "drive_c/save.dat")),
            Data("progress".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bottleURL.appending(path: "drive_c/empty").path
        ))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: result.bottleURL.appending(path: "dosdevices/c:").path
            ),
            "../drive_c"
        )
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.byteCount, Int64(sourceMetadata.count + Data("progress".utf8).count))
        let staging = try FileManager.default.contentsOfDirectory(
            at: destinationRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".import-") }
        XCTAssertTrue(staging.isEmpty)
    }

    func testDestinationCollisionDoesNotTouchEitherBottle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appending(path: "source")
        let destinationRoot = fixture.appending(path: "destination")
        try makeBottle(at: source)
        let identifier = UUID()
        let existing = destinationRoot.appending(path: identifier.uuidString)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appending(path: "marker"))

        XCTAssertThrowsError(try BottleImporter.copy(
            bottleAt: source,
            to: destinationRoot,
            identifier: identifier
        )) { error in
            XCTAssertEqual(error as? BottleImportError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: existing.appending(path: "marker")), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appending(path: "Metadata.plist").path))
    }

    func testDestinationCannotOverlapSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appending(path: "source")
        try makeBottle(at: source)

        XCTAssertThrowsError(try BottleImporter.copy(
            bottleAt: source,
            to: source.appending(path: "copies")
        )) { error in
            XCTAssertEqual(error as? BottleImportError, .pathsOverlap)
        }
    }

    func testMissingOrOrdinaryDirectoryIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let ordinary = fixture.appending(path: "ordinary")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BottleImporter.copy(
            bottleAt: fixture.appending(path: "missing"),
            to: fixture.appending(path: "destination")
        )) { error in
            XCTAssertEqual(error as? BottleImportError, .sourceMissing)
        }
        XCTAssertThrowsError(try BottleImporter.copy(
            bottleAt: ordinary,
            to: fixture.appending(path: "destination")
        )) { error in
            XCTAssertEqual(error as? BottleImportError, .sourceIsNotBottle)
        }
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "BottleImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBottle(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: "drive_c/empty"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: url.appending(path: "dosdevices"),
            withIntermediateDirectories: true
        )
        try Data("metadata".utf8).write(to: url.appending(path: "Metadata.plist"))
        try Data("progress".utf8).write(to: url.appending(path: "drive_c/save.dat"))
        try FileManager.default.createSymbolicLink(
            atPath: url.appending(path: "dosdevices/c:").path,
            withDestinationPath: "../drive_c"
        )
    }
}
