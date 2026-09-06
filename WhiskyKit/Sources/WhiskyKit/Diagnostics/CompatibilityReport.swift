//
//  CompatibilityReport.swift
//  WhiskyKit
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

public struct CompatibilityApplicationInfo: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let build: String

    public init(name: String, version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }
}

public struct CompatibilityGameInfo: Codable, Equatable, Sendable {
    public let name: String
    public let source: String
    public let steamAppID: Int?
    public let executableName: String?

    public init(
        name: String,
        source: String,
        steamAppID: Int? = nil,
        executableName: String? = nil
    ) {
        self.name = name
        self.source = source
        self.steamAppID = steamAppID
        self.executableName = executableName
    }
}

public struct CompatibilityRuntimeComponentInfo: Codable, Equatable, Sendable {
    public let name: String
    public let version: String?
    public let license: String
    public let sha256: String?
}

public struct CompatibilityRuntimeInfo: Codable, Equatable, Sendable {
    public let slotID: String?
    public let channel: String?
    public let version: String?
    public let archiveSHA256: String?
    public let selectionReason: String
    public let capabilities: [String]
    public let components: [CompatibilityRuntimeComponentInfo]
}

public struct CompatibilityProfileInfo: Codable, Equatable, Sendable {
    public let databaseEntryID: String?
    public let databaseRating: String?
    public let variantID: String?
    public let variantLabel: String?
    public let graphicsBackend: String
    public let provenance: [String]
}

public struct CompatibilityLaunchInfo: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date?
    public let durationSeconds: Double?
    public let stage: String
    public let failureCode: String?
}

/// A deliberately bounded result that can be inspected before it is shared.
///
/// It contains no bottle or save paths, save contents, transaction identifiers,
/// account details, launch arguments, environment values, tokens, or raw logs.
public struct CompatibilityReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let application: CompatibilityApplicationInfo
    public let game: CompatibilityGameInfo
    public let hardware: HardwareProfile
    public let runtime: CompatibilityRuntimeInfo
    public let profile: CompatibilityProfileInfo
    public let savePolicy: GameSavePolicy?
    public let preflight: LaunchPreflightReport
    public let lastLaunch: CompatibilityLaunchInfo?
    public let errorSignatures: [String]
    public let privacy: String
}

public struct CompatibilityReportInput: Sendable {
    public let application: CompatibilityApplicationInfo
    public let game: CompatibilityGameInfo
    public let hardware: HardwareProfile
    public let runtime: RuntimeSelection
    public let preflight: LaunchPreflightReport
    public var databaseEntry: GameDBEntry?
    public var variant: GameConfigVariant?
    public var profileProvenance: [String]
    public var savePolicy: GameSavePolicy?
    public var lastLaunch: LaunchTransactionRecord?
    public var generatedAt: Date

    public init(
        application: CompatibilityApplicationInfo,
        game: CompatibilityGameInfo,
        hardware: HardwareProfile,
        runtime: RuntimeSelection,
        preflight: LaunchPreflightReport
    ) {
        self.application = application
        self.game = game
        self.hardware = hardware
        self.runtime = runtime
        self.preflight = preflight
        self.databaseEntry = nil
        self.variant = nil
        self.profileProvenance = []
        self.savePolicy = nil
        self.lastLaunch = nil
        self.generatedAt = Date()
    }
}

public enum CompatibilityReportExporter {
    public static func make(_ input: CompatibilityReportInput) -> CompatibilityReport {
        let cleanPreflight = sanitized(input.preflight)
        let launch = launchInfo(input.lastLaunch)
        return CompatibilityReport(
            schemaVersion: CompatibilityReport.currentSchemaVersion,
            generatedAt: input.generatedAt,
            application: CompatibilityApplicationInfo(
                name: ProductIdentity.name,
                version: clean(input.application.version),
                build: clean(input.application.build)
            ),
            game: CompatibilityGameInfo(
                name: clean(input.game.name),
                source: clean(input.game.source),
                steamAppID: input.game.steamAppID,
                executableName: input.game.executableName.map {
                    clean(URL(fileURLWithPath: $0).lastPathComponent)
                }
            ),
            hardware: input.hardware,
            runtime: runtimeInfo(input.runtime),
            profile: profileInfo(input, preflight: cleanPreflight),
            savePolicy: input.savePolicy,
            preflight: cleanPreflight,
            lastLaunch: launch,
            errorSignatures: errorSignatures(preflight: cleanPreflight, launch: launch),
            privacy: "No paths, save contents, account details, tokens, or raw logs are included."
        )
    }

    public static func data(for report: CompatibilityReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    public static func suggestedFilename(gameName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let words = gameName.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let slug = words.joined(separator: "-").lowercased()
        return "openbottle-\(slug.isEmpty ? "game" : slug)-compatibility.json"
    }

    private static func clean(_ value: String) -> String {
        Redactor.redactLogText(value)
    }

    private static func sanitized(_ report: LaunchPreflightReport) -> LaunchPreflightReport {
        LaunchPreflightReport(
            findings: report.findings.map {
                LaunchPreflightFinding(
                    id: clean($0.id),
                    severity: $0.severity,
                    title: clean($0.title),
                    detail: clean($0.detail),
                    nextAction: $0.nextAction.map(clean)
                )
            },
            resolvedBackend: report.resolvedBackend,
            runtimeSlotID: report.runtimeSlotID.map(clean)
        )
    }

    private static func launchInfo(_ record: LaunchTransactionRecord?) -> CompatibilityLaunchInfo? {
        record.map {
            CompatibilityLaunchInfo(
                startedAt: $0.createdAt,
                finishedAt: $0.stage.isTerminal ? $0.updatedAt : nil,
                durationSeconds: $0.stage.isTerminal
                    ? max(0, $0.updatedAt.timeIntervalSince($0.createdAt))
                    : nil,
                stage: $0.stage.rawValue,
                failureCode: $0.failureCode.map(clean)
            )
        }
    }

    private static func runtimeInfo(_ runtime: RuntimeSelection) -> CompatibilityRuntimeInfo {
        CompatibilityRuntimeInfo(
            slotID: runtime.slotID.map(clean),
            channel: runtime.manifest.map(\.channel.rawValue),
            version: runtime.manifest.map { clean($0.runtimeVersion) },
            archiveSHA256: runtime.manifest.map { clean($0.archiveSHA256) },
            selectionReason: clean(runtime.reason),
            capabilities: runtime.manifest?.capabilities.map(clean).sorted() ?? [],
            components: runtime.manifest?.components.map {
                CompatibilityRuntimeComponentInfo(
                    name: clean($0.name),
                    version: $0.version.map(clean),
                    license: clean($0.license),
                    sha256: $0.sha256.map(clean)
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? []
        )
    }

    private static func profileInfo(
        _ input: CompatibilityReportInput,
        preflight: LaunchPreflightReport
    ) -> CompatibilityProfileInfo {
        CompatibilityProfileInfo(
            databaseEntryID: input.databaseEntry.map { clean($0.id) },
            databaseRating: input.databaseEntry?.rating.rawValue,
            variantID: input.variant.map { clean($0.id) },
            variantLabel: input.variant.map { clean($0.label) },
            graphicsBackend: preflight.resolvedBackend.rawValue,
            provenance: input.profileProvenance.map(clean)
        )
    }

    private static func errorSignatures(
        preflight: LaunchPreflightReport,
        launch: CompatibilityLaunchInfo?
    ) -> [String] {
        var signatures = preflight.findings
            .filter { $0.severity != .information }
            .map(\.id)
        if let failureCode = launch?.failureCode {
            signatures.append(failureCode)
        }
        return Array(Set(signatures)).sorted()
    }
}
