//
//  HardwareProfile.swift
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

import CoreGraphics
import Foundation
import Metal

public struct HardwareProfile: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let chipName: String
    public let gpuName: String
    public let memoryGB: Int
    public let displayWidth: Int
    public let displayHeight: Int
    public let refreshRate: Double
    public let macOSVersion: String
    public let cpuArchitecture: String

    public init(
        modelIdentifier: String,
        chipName: String,
        gpuName: String,
        memoryGB: Int,
        displayWidth: Int,
        displayHeight: Int,
        refreshRate: Double,
        macOSVersion: String,
        cpuArchitecture: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.chipName = chipName
        self.gpuName = gpuName
        self.memoryGB = memoryGB
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.refreshRate = refreshRate
        self.macOSVersion = macOSVersion
        self.cpuArchitecture = cpuArchitecture
    }

    public static func current() -> HardwareProfile {
        let display = CGMainDisplayID()
        let displayMode = CGDisplayCopyDisplayMode(display)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HardwareProfile(
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            chipName: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            gpuName: MTLCreateSystemDefaultDevice()?.name ?? "unknown",
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            displayWidth: displayMode?.pixelWidth ?? Int(CGDisplayPixelsWide(display)),
            displayHeight: displayMode?.pixelHeight ?? Int(CGDisplayPixelsHigh(display)),
            refreshRate: refreshRate(for: display),
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            cpuArchitecture: machineArchitecture()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func refreshRate(for display: CGDirectDisplayID) -> Double {
        if let current = CGDisplayCopyDisplayMode(display), current.refreshRate > 0 {
            return current.refreshRate
        }
        let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] ?? []
        return modes.map(\.refreshRate).max() ?? 0
    }
}
