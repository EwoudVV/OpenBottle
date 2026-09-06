//
//  SteamGameSavePlan.swift
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

struct SteamGameSavePlan: Sendable {
    let gameID: String
    let sources: [SaveSource]
}

enum SteamGameSavePlanner {
    static func resolve(
        game: SteamGame,
        bottleURL: URL,
        entries: [GameDBEntry],
        wineUserName: String?
    ) throws -> SteamGameSavePlan {
        let entry = entries.first { $0.steamAppId == game.appId }
        let locations = entry?.saveLocations ?? []
        let sources = try GameSaveResolver.resolve(
            locations,
            context: GameSaveContext(
                bottleURL: bottleURL,
                gameInstallURL: game.installURL,
                wineUserName: wineUserName
            )
        )
        return SteamGameSavePlan(
            gameID: entry?.id ?? "steam-\(game.appId)",
            sources: sources
        )
    }

    static func game(
        for gameID: String,
        among games: [SteamGame],
        entries: [GameDBEntry]
    ) -> SteamGame? {
        if let appID = entries.first(where: { $0.id == gameID })?.steamAppId {
            return games.first { $0.appId == appID }
        }
        guard gameID.hasPrefix("steam-"),
              let appID = Int(gameID.dropFirst("steam-".count))
        else { return nil }
        return games.first { $0.appId == appID }
    }
}
