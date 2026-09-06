//
//  CompatibilityBlockerScanner.swift
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

public enum CompatibilityBlockerScanner {
    private static let maximumFiles = 10_000
    private static let kernelDriverPatterns = [
        "ace-base.sys",
        "bedaisy.sys",
        "easyanticheat.sys",
        "easyanticheat_eos.sys",
        "mhyprot",
        "vgk.sys",
        "xhunter"
    ]
    private static let antiCheatPatterns = [
        "battleye",
        "easyanticheat",
        "eac_launcher"
    ]
    private static let drmPatterns = ["denuvo", "vmprotect"]

    public static func findings(
        installURL: URL,
        entry: GameDBEntry?
    ) -> [LaunchPreflightFinding] {
        var findings: [LaunchPreflightFinding] = []
        if entry?.rating == .notSupported {
            findings.append(blocked(
                id: "known-not-supported",
                title: "Known compatibility blocker",
                detail: "This game is marked not supported with the current macOS Wine stack."
            ))
        }
        if entry?.antiCheat?.lowercased() == "vanguard" {
            findings.append(blocked(
                id: "kernel-anticheat-vanguard",
                title: "Kernel anti-cheat required",
                detail: "Riot Vanguard requires Windows kernel drivers that Wine cannot provide."
            ))
        }

        let names = scannedNames(under: installURL)
        if let driver = names.first(where: matchesKernelDriver) {
            findings.append(blocked(
                id: "kernel-driver-\(opaqueName(driver))",
                title: "Kernel anti-cheat required",
                detail: "The game includes \(driver), a Windows kernel anti-cheat driver."
            ))
        } else if entry?.antiCheat != nil || names.contains(where: matchesAntiCheat) {
            findings.append(LaunchPreflightFinding(
                id: "anticheat-warning",
                severity: .warning,
                title: "Anti-cheat may limit play",
                detail: "Online play may require the developer to enable Wine support. Offline modes may still work.",
                nextAction: "Try the game's offline or anti-cheat-free launch option."
            ))
        }
        if names.contains(where: matchesDRM) {
            findings.append(LaunchPreflightFinding(
                id: "drm-warning",
                severity: .warning,
                title: "DRM detected",
                detail: "This build includes DRM that may reject Wine after an update.",
                nextAction: "Keep this runtime pinned and report the exact game build if launch fails."
            ))
        }
        return unique(findings)
    }

    private static func scannedNames(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        else { return [] }
        var names: [String] = []
        for case let url as URL in enumerator {
            if names.count >= maximumFiles { break }
            names.append(url.lastPathComponent.lowercased())
        }
        return names
    }

    private static func matchesKernelDriver(_ name: String) -> Bool {
        kernelDriverPatterns.contains { pattern in
            pattern.hasSuffix(".sys") ? name == pattern : name.contains(pattern)
        }
    }

    private static func matchesAntiCheat(_ name: String) -> Bool {
        antiCheatPatterns.contains { name.contains($0) }
    }

    private static func matchesDRM(_ name: String) -> Bool {
        drmPatterns.contains { name.contains($0) }
    }

    private static func blocked(
        id: String,
        title: String,
        detail: String
    ) -> LaunchPreflightFinding {
        LaunchPreflightFinding(
            id: id,
            severity: .blocked,
            title: title,
            detail: detail,
            nextAction: "Use a native Mac build, a remote Windows PC, or cloud gaming for this title."
        )
    }

    private static func opaqueName(_ name: String) -> String {
        name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func unique(_ findings: [LaunchPreflightFinding]) -> [LaunchPreflightFinding] {
        var identifiers = Set<String>()
        return findings.filter { identifiers.insert($0.id).inserted }
    }
}
