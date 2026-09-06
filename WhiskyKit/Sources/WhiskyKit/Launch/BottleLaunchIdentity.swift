//
//  BottleLaunchIdentity.swift
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

import CryptoKit
import Foundation

/// Gives each registered bottle a private, deterministic launch-safety scope.
public enum BottleLaunchIdentity {
    /// Produces an opaque ID without persisting the bottle's local path.
    public static func id(for bottleURL: URL) -> String {
        let canonicalPath = bottleURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "bottle-\(digest)"
    }
}
