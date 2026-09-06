//
//  CompatibilityReportTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Compatibility report")
struct CompatibilityReportTests {
    // swiftlint:disable function_body_length
    @Test("Export is useful without exposing paths, account names, secrets, or raw logs")
    func privateFieldsStayOut() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = started.addingTimeInterval(42)
        let runtime = try RuntimeSelection(
            slotID: "stable-3.1.1",
            libraryURL: URL(fileURLWithPath: "/Users/alice/Library/Secret Runtime"),
            manifest: RuntimeSlotManifest(
                id: "stable-3.1.1",
                channel: .stable,
                runtimeVersion: "3.1.1",
                createdAt: started,
                sourceURL: URL(string: "https://example.com/runtime.tar.gz"),
                archiveSHA256: "archive-hash",
                components: [
                    RuntimeComponentManifest(
                        name: "Wine",
                        version: "9.0",
                        license: "LGPL-2.1-or-later",
                        sourceURL: #require(URL(string: "https://example.com/wine")),
                        representativePath: "/Users/alice/Wine/bin/wine64",
                        sha256: "wine-hash"
                    )
                ],
                capabilities: ["dxvk", "dxmt"]
            ),
            reason: "last successful launch for /Users/alice"
        )
        let preflight = LaunchPreflightReport(
            findings: [
                LaunchPreflightFinding(
                    id: "backend-warning",
                    severity: .warning,
                    title: "Fallback",
                    detail: #"C:\Users\Alice\Games\game.exe failed with token=secret-value"#,
                    nextAction: "Read /home/alice/private.log"
                )
            ],
            resolvedBackend: .dxmt,
            runtimeSlotID: runtime.slotID
        )
        let launch = LaunchTransactionRecord(
            id: UUID(),
            bottleID: "private-bottle-id",
            gameID: "private-game-id",
            runtimeSlotID: runtime.slotID,
            stage: .failed,
            createdAt: started,
            updatedAt: finished,
            failureCode: "program-launch-failed"
        )

        var input = CompatibilityReportInput(
            application: CompatibilityApplicationInfo(
                name: ProductIdentity.name,
                version: "0.1.0",
                build: "1"
            ),
            game: CompatibilityGameInfo(
                name: "Example Game",
                source: "steam",
                steamAppID: 123
            ),
            hardware: HardwareProfile(
                modelIdentifier: "MacBookPro18,2",
                chipName: "Apple M1 Max",
                gpuName: "Apple M1 Max",
                memoryGB: 64,
                displayWidth: 3_456,
                displayHeight: 2_234,
                refreshRate: 120,
                macOSVersion: "26.0.0",
                cpuArchitecture: "arm64"
            ),
            runtime: runtime,
            preflight: preflight
        )
        input.profileProvenance = ["profile from /Users/alice/profile.json --password hunter2"]
        input.savePolicy = .localOnly
        input.lastLaunch = launch
        input.generatedAt = finished
        let report = CompatibilityReportExporter.make(input)
        let data = try CompatibilityReportExporter.data(for: report)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("MacBookPro18,2"))
        #expect(text.contains("stable-3.1.1"))
        #expect(text.contains("archive-hash"))
        #expect(text.contains("program-launch-failed"))
        #expect(text.contains("<redacted>"))
        #expect(!text.localizedCaseInsensitiveContains("alice"))
        #expect(!text.contains("secret-value"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("private-bottle-id"))
        #expect(!text.contains("private-game-id"))
        #expect(!text.contains("Secret Runtime"))
        #expect(!text.contains("representativePath"))
        #expect(report.lastLaunch?.durationSeconds == 42)
        #expect(report.errorSignatures == ["backend-warning", "program-launch-failed"])
    }

    // swiftlint:enable function_body_length

    @Test("Suggested filenames are portable and never contain a path")
    func portableFilename() {
        #expect(
            CompatibilityReportExporter.suggestedFilename(gameName: "Screw Drivers: Test / Build")
                == "openbottle-screw-drivers-test-build-compatibility.json"
        )
    }
}
