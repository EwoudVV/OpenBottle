//
//  LaunchPreflight.swift
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

public enum LaunchPreflightSeverity: String, Codable, Equatable, Sendable {
    case information
    case warning
    case blocked
}

public struct LaunchPreflightFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let severity: LaunchPreflightSeverity
    public let title: String
    public let detail: String
    public let nextAction: String?

    public init(
        id: String,
        severity: LaunchPreflightSeverity,
        title: String,
        detail: String,
        nextAction: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.nextAction = nextAction
    }
}

public struct LaunchPreflightReport: Codable, Equatable, Sendable {
    public let findings: [LaunchPreflightFinding]
    public let resolvedBackend: GraphicsBackend
    public let runtimeSlotID: String?

    public var canLaunch: Bool {
        !findings.contains { $0.severity == .blocked }
    }

    public init(
        findings: [LaunchPreflightFinding],
        resolvedBackend: GraphicsBackend,
        runtimeSlotID: String?
    ) {
        self.findings = findings
        self.resolvedBackend = resolvedBackend
        self.runtimeSlotID = runtimeSlotID
    }
}

public enum LaunchPreflightError: LocalizedError {
    case blocked(LaunchPreflightReport)

    public var errorDescription: String? {
        switch self {
        case let .blocked(report):
            guard let finding = report.findings.first(where: { $0.severity == .blocked }) else {
                return "This game cannot launch with the current setup"
            }
            return [finding.detail, finding.nextAction].compactMap { $0 }.joined(separator: " ")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case let .blocked(report):
            report.findings.first { $0.severity == .blocked }?.nextAction
        }
    }
}

public struct LaunchPreflightInput: Sendable {
    public let bottleURL: URL
    public let programURL: URL?
    public let installURL: URL
    public let entry: GameDBEntry?
    public let launcher: LauncherType?
    public let backend: GraphicsBackend
    public let runtime: RuntimeSelection
    public let isAppleSilicon: Bool
    public let isRosettaInstalled: Bool
    public let macOSVersion: MacOSVersion

    public init(
        bottleURL: URL,
        programURL: URL?,
        installURL: URL,
        entry: GameDBEntry?,
        launcher: LauncherType?,
        backend: GraphicsBackend,
        runtime: RuntimeSelection,
        isAppleSilicon: Bool = HostArchitecture.isAppleSilicon,
        isRosettaInstalled: Bool = Rosetta2.isRosettaInstalled,
        macOSVersion: MacOSVersion = .current
    ) {
        self.bottleURL = bottleURL
        self.programURL = programURL
        self.installURL = installURL
        self.entry = entry
        self.launcher = launcher
        self.backend = backend
        self.runtime = runtime
        self.isAppleSilicon = isAppleSilicon
        self.isRosettaInstalled = isRosettaInstalled
        self.macOSVersion = macOSVersion
    }
}

public enum LaunchPreflight {
    @MainActor
    public static func evaluate(_ input: LaunchPreflightInput) async -> LaunchPreflightReport {
        await RuntimeContext.withLibrary(input.runtime.libraryURL) {
            let runtimeInfo = WhiskyWineInstaller.whiskyWineInfo(
                at: input.runtime.libraryURL.appending(path: "WhiskyWineVersion.plist")
            )
            let d3DMetal = WhiskyWineInstaller.isD3DMetalPresent(
                inLibraryFolder: input.runtime.libraryURL
            )
            let dxmt = Wine.isDXMTRuntimeNative()
            let backend = input.backend == .recommended
                ? GraphicsBackendResolver.resolve(
                    for: input.launcher,
                    macOSVersion: input.macOSVersion,
                    runtimeInfo: runtimeInfo,
                    d3dMetalInstalled: d3DMetal,
                    dxmtRuntimeNative: dxmt
                )
                : input.backend
            var findings = basicFindings(input, runtimeInfo: runtimeInfo)
            findings += backendFindings(
                backend,
                runtimeInfo: runtimeInfo,
                d3DMetalInstalled: d3DMetal,
                dxmtRuntimeNative: dxmt
            )
            findings += CompatibilityBlockerScanner.findings(
                installURL: input.installURL,
                entry: input.entry
            )
            return LaunchPreflightReport(
                findings: findings,
                resolvedBackend: backend,
                runtimeSlotID: input.runtime.slotID
            )
        }
    }

    private static func basicFindings(
        _ input: LaunchPreflightInput,
        runtimeInfo: WhiskyWineVersion?
    ) -> [LaunchPreflightFinding] {
        var findings: [LaunchPreflightFinding] = []
        if !WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: input.runtime.libraryURL)
            || runtimeInfo == nil {
            findings.append(blocked(
                id: "runtime-missing",
                title: "Runtime needed",
                detail: "OpenBottle does not have a usable Windows runtime.",
                action: "Install the Stable runtime, then try again."
            ))
        }
        if input.isAppleSilicon, !input.isRosettaInstalled {
            findings.append(blocked(
                id: "rosetta-missing",
                title: "Rosetta needed",
                detail: "This Mac needs Rosetta to run the current x86 Windows runtime.",
                action: "Install Rosetta from OpenBottle setup, then try again."
            ))
        }
        if !FileManager.default.fileExists(atPath: input.bottleURL.path(percentEncoded: false)) {
            findings.append(blocked(
                id: "bottle-missing",
                title: "Game data missing",
                detail: "The game's OpenBottle data folder is unavailable.",
                action: "Reconnect its drive or import the game again."
            ))
        }
        findings += executableFindings(input.programURL)
        return findings
    }

    private static func executableFindings(_ url: URL?) -> [LaunchPreflightFinding] {
        guard let url else { return [] }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return [blocked(
                id: "program-missing",
                title: "Program missing",
                detail: "The Windows program is no longer at its saved location.",
                action: "Find or reinstall the program, then update this library entry."
            )]
        }
        guard let executable = try? PEFile(url: url) else { return [] }
        if executable.coffFileHeader.machine == 0xAA64 {
            return [blocked(
                id: "windows-arm64",
                title: "Windows ARM app",
                detail: "This runtime runs x86 Windows programs; this file is Windows ARM64.",
                action: "Install the x64 or x86 build of this program."
            )]
        }
        return []
    }

    private static func backendFindings(
        _ backend: GraphicsBackend,
        runtimeInfo: WhiskyWineVersion?,
        d3DMetalInstalled: Bool,
        dxmtRuntimeNative: Bool
    ) -> [LaunchPreflightFinding] {
        guard !WhiskyWineInstaller.backendAvailability(
            backend,
            runtimeInfo: runtimeInfo,
            d3dMetalInstalled: d3DMetalInstalled,
            dxmtRuntimeNative: dxmtRuntimeNative
        )
        else { return [] }
        return [blocked(
            id: "backend-unavailable",
            title: "Graphics backend unavailable",
            detail: "The selected runtime does not contain the requested graphics backend.",
            action: "Use Recommended or choose a runtime that provides this backend."
        )]
    }

    private static func blocked(
        id: String,
        title: String,
        detail: String,
        action: String
    ) -> LaunchPreflightFinding {
        LaunchPreflightFinding(
            id: id,
            severity: .blocked,
            title: title,
            detail: detail,
            nextAction: action
        )
    }
}
