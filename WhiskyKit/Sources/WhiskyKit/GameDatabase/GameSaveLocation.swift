//
//  GameSaveLocation.swift
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

/// Portable roots a GameDB save location can use.
public enum GameSaveRoot: String, Codable, Equatable, Sendable {
    case gameInstall
    case wineUserProfile
    case documents
    case savedGames
    case appDataRoaming
    case appDataLocal
    case appDataLocalLow
}

/// One file or directory in a game's save plan.
public struct GameSaveLocation: Codable, Equatable, Sendable {
    public let id: String
    public let root: GameSaveRoot
    public let path: String
    public let kind: SaveSourceKind
    public let required: Bool

    public init(
        id: String,
        root: GameSaveRoot,
        path: String,
        kind: SaveSourceKind,
        required: Bool = false
    ) {
        self.id = id
        self.root = root
        self.path = path
        self.kind = kind
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        root = try container.decode(GameSaveRoot.self, forKey: .root)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decode(SaveSourceKind.self, forKey: .kind)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }
}

/// Machine-specific roots needed to resolve portable GameDB save locations.
public struct GameSaveContext: Equatable, Sendable {
    public let bottleURL: URL
    public let gameInstallURL: URL
    public let wineUserName: String

    public init(
        bottleURL: URL,
        gameInstallURL: URL,
        wineUserName: String? = nil
    ) {
        self.bottleURL = bottleURL
        self.gameInstallURL = gameInstallURL
        let usersDirectory = bottleURL.appending(path: "drive_c/users")
        self.wineUserName = wineUserName
            ?? WinePrefixValidation.detectWineUsername(in: usersDirectory)
            ?? NSUserName()
    }
}

public enum GameSaveResolverError: LocalizedError, Equatable {
    case invalidRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path):
            "Invalid relative save path: \(path)"
        }
    }
}

/// Resolves a portable GameDB save plan inside one Wine bottle.
public enum GameSaveResolver {
    public static func resolve(
        _ locations: [GameSaveLocation],
        context: GameSaveContext
    ) throws -> [SaveSource] {
        try locations.map { location in
            try SaveVault.validateIdentifier(location.id)
            try validate(path: location.path, kind: location.kind)
            let root = rootURL(for: location.root, context: context)
            let url = location.path.isEmpty ? root : root.appending(path: location.path)
            return SaveSource(
                id: location.id,
                url: url,
                kind: location.kind,
                required: location.required
            )
        }
    }

    private static func rootURL(for root: GameSaveRoot, context: GameSaveContext) -> URL {
        let profile = context.bottleURL.appending(path: "drive_c/users/\(context.wineUserName)")
        return switch root {
        case .gameInstall:
            context.gameInstallURL
        case .wineUserProfile:
            profile
        case .documents:
            profile.appending(path: "Documents")
        case .savedGames:
            profile.appending(path: "Saved Games")
        case .appDataRoaming:
            profile.appending(path: "AppData/Roaming")
        case .appDataLocal:
            profile.appending(path: "AppData/Local")
        case .appDataLocalLow:
            profile.appending(path: "AppData/LocalLow")
        }
    }

    private static func validate(path: String, kind _: SaveSourceKind) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\")
        else {
            throw GameSaveResolverError.invalidRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GameSaveResolverError.invalidRelativePath(path)
        }
    }
}
