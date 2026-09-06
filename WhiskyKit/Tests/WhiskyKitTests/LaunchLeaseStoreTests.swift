//
//  LaunchLeaseStoreTests.swift
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

final class LaunchLeaseStoreTests: XCTestCase {
    func testLeaseIsExclusiveAndOnlyItsOwnerCanReleaseIt() async throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchLeaseStore(rootURL: root, processID: 42)
        let firstID = UUID()
        let secondID = UUID()

        let lease = try await store.acquire(
            bottleID: "test-bottle",
            transactionID: firstID
        )
        XCTAssertEqual(lease.transactionID, firstID)

        do {
            _ = try await store.acquire(
                bottleID: "test-bottle",
                transactionID: secondID
            )
            XCTFail("Expected the bottle to be busy")
        } catch {
            XCTAssertEqual(error as? LaunchLeaseError, .bottleBusy)
        }
        do {
            try await store.release(bottleID: "test-bottle", transactionID: secondID)
            XCTFail("Expected the owner check to fail")
        } catch {
            XCTAssertEqual(error as? LaunchLeaseError, .leaseOwnedByAnotherLaunch)
        }

        try await store.release(bottleID: "test-bottle", transactionID: firstID)
        let remaining = try await store.lease(for: "test-bottle")
        XCTAssertNil(remaining)
    }

    func testDeadOwnerRequiresRecoveryInsteadOfStealingTheLease() async throws {
        let root = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = LaunchLeaseStore(rootURL: root, processID: Int32.max)
        let oldID = UUID()
        _ = try await oldStore.acquire(bottleID: "test-bottle", transactionID: oldID)
        let currentStore = LaunchLeaseStore(rootURL: root)

        do {
            _ = try await currentStore.acquire(
                bottleID: "test-bottle",
                transactionID: UUID()
            )
            XCTFail("Expected recovery to be required")
        } catch {
            XCTAssertEqual(error as? LaunchLeaseError, .recoveryRequired)
        }

        let retainedLease = try await currentStore.lease(for: "test-bottle")
        XCTAssertEqual(retainedLease?.transactionID, oldID)
    }

    private func makeFixture() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "LaunchLeaseStoreTests-\(UUID().uuidString)")
    }
}
