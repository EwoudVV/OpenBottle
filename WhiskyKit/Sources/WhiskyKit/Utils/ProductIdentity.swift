//
//  ProductIdentity.swift
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

/// Stable public identity shared by every OpenBottle entry point.
public enum ProductIdentity {
    public static let name = "OpenBottle"
    public static let appBundleIdentifier = "io.github.ewoudvv.OpenBottle"
    public static let commandName = "openbottle"
    public static let commandExecutable = "OpenBottleCmd"
    public static let urlScheme = "openbottle"
    public static let repositoryURL = URL(string: "https://github.com/EwoudVV/OpenBottle")
    public static let issuesURL = URL(string: "https://github.com/EwoudVV/OpenBottle/issues")

    /// Existing Whisky variants OpenBottle can discover without writing to them.
    public static let legacyBundleIdentifiers = [
        "com.franke.Whisky",
        "com.isaacmarovitz.Whisky"
    ]
}
