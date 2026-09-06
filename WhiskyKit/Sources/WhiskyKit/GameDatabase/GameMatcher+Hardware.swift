//
//  GameMatcher+Hardware.swift
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

extension GameMatcher {
    /// Selects the most specific eligible variant, keeping the default for unknown hardware.
    static func selectVariant(
        from entry: GameDBEntry,
        hardwareProfile: HardwareProfile
    ) -> GameConfigVariant? {
        guard !entry.variants.isEmpty else { return nil }
        let eligible = entry.variants.enumerated().filter {
            constraintsMatch($0.element.constraints, hardware: hardwareProfile)
        }
        guard !eligible.isEmpty else { return entry.defaultVariant }
        return eligible.max { lhs, rhs in
            let lhsScore = hardwareScore(lhs.element, hardware: hardwareProfile)
            let rhsScore = hardwareScore(rhs.element, hardware: hardwareProfile)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.offset > rhs.offset
        }?.element
    }

    private static func constraintsMatch(
        _ constraints: GameConstraints?,
        hardware: HardwareProfile
    ) -> Bool {
        guard let constraints else { return true }
        if let architectures = constraints.cpuArchitectures,
           !architectures.contains(where: { $0.caseInsensitiveCompare(hardware.cpuArchitecture) == .orderedSame }) {
            return false
        }
        if let models = constraints.macModels,
           !models.contains(where: { $0.caseInsensitiveCompare(hardware.modelIdentifier) == .orderedSame }) {
            return false
        }
        if let families = constraints.gpuFamilies {
            let names = "\(hardware.chipName) \(hardware.gpuName)".lowercased()
            if !families.contains(where: { names.contains($0.lowercased()) }) { return false }
        }
        if let memory = constraints.minimumMemoryGB, hardware.memoryGB < memory { return false }
        if let widths = constraints.displayWidths, !widths.contains(hardware.displayWidth) { return false }
        if let heights = constraints.displayHeights, !heights.contains(hardware.displayHeight) { return false }
        if let refresh = constraints.minimumRefreshRate, hardware.refreshRate < refresh { return false }
        return true
    }

    private static func hardwareScore(
        _ variant: GameConfigVariant,
        hardware: HardwareProfile
    ) -> Int {
        var score = variant.isDefault == true ? 1 : 0
        let tested = variant.testedWith
        if tested?.macModel?.caseInsensitiveCompare(hardware.modelIdentifier) == .orderedSame {
            score += 100
        }
        let names = "\(hardware.chipName) \(hardware.gpuName)".lowercased()
        if let gpu = tested?.gpuName, names.contains(gpu.lowercased()) { score += 40 }
        if tested?.memoryGB == hardware.memoryGB { score += 20 }
        if tested?.displayWidth == hardware.displayWidth,
           tested?.displayHeight == hardware.displayHeight {
            score += 40
        }
        if let refresh = tested?.refreshRate, abs(refresh - hardware.refreshRate) < 1 {
            score += 15
        }
        if tested?.cpuArchitecture?.caseInsensitiveCompare(hardware.cpuArchitecture) == .orderedSame {
            score += 5
        }
        if variant.constraints != nil { score += 10 }
        return score
    }
}
