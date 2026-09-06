//
//  RuntimeContext.swift
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

/// Selects a runtime per asynchronous launch without changing a global symlink.
public enum RuntimeContext {
    @TaskLocal public static var libraryURL: URL?

    public static var resolvedLibraryURL: URL {
        libraryURL ?? WhiskyWineInstaller.libraryFolder
    }

    public static var binURL: URL {
        resolvedLibraryURL.appending(path: "Wine/bin")
    }

    @MainActor
    public static func withLibrary<T>(
        _ url: URL,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $libraryURL.withValue(url, operation: operation)
    }
}
