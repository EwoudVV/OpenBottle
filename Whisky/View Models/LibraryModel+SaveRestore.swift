//
//  LibraryModel+SaveRestore.swift
//  Whisky
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
import WhiskyKit

struct LibraryRestoreSheet: Identifiable {
    let row: LibraryRow
    let game: SteamGame
    let inventory: SaveSnapshotInventory

    var id: String { row.id }
}

enum LibrarySaveError: LocalizedError {
    case gameRunning
    case gameUnavailable

    var errorDescription: String? {
        switch self {
        case .gameRunning:
            String(localized: "library.saves.gameRunning")
        case .gameUnavailable:
            String(localized: "library.saves.gameUnavailable")
        }
    }
}

extension LibraryModel {
    func canManageSaves(for row: LibraryRow) -> Bool {
        guard case let .steam(appID) = row.item.launch else { return false }
        return saveSafety.hasSavePlan(steamAppID: appID)
    }

    func showRestorePoints(for row: LibraryRow, bottles: [Bottle]) async {
        do {
            let target = try steamTarget(for: row, bottles: bottles)
            let inventory = try await saveSafety.inventory(
                game: target.game,
                bottleURL: target.bottle.url
            )
            restoreSheet = LibraryRestoreSheet(
                row: row,
                game: target.game,
                inventory: inventory
            )
        } catch {
            saveError = error.localizedDescription
        }
    }

    func restore(
        _ snapshot: SaveSnapshot,
        from sheet: LibraryRestoreSheet,
        bottles: [Bottle]
    ) async {
        let entryID = sheet.row.id
        guard !restoringEntryIDs.contains(entryID) else { return }
        restoringEntryIDs.insert(entryID)
        defer { restoringEntryIDs.remove(entryID) }

        do {
            let target = try steamTarget(for: sheet.row, bottles: bottles)
            let running = await orchestrator(for: target.bottle).runningAppIDs(in: [target.game])
            guard !running.contains(target.game.appId) else {
                throw LibrarySaveError.gameRunning
            }
            _ = try await saveSafety.restore(
                snapshot: snapshot,
                game: target.game,
                bottleURL: target.bottle.url
            )
            restoreSheet = nil
            toast = ToastData(
                message: String(localized: "library.saves.restored"),
                style: .success
            )
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func steamTarget(
        for row: LibraryRow,
        bottles: [Bottle]
    ) throws -> (bottle: Bottle, game: SteamGame) {
        guard case let .steam(appID) = row.item.launch,
              let bottle = bottles.first(where: { $0.url == row.item.bottleURL }),
              let game = SteamLibrary.enumerate(bottleURL: bottle.url).first(where: { $0.appId == appID })
        else {
            throw LibrarySaveError.gameUnavailable
        }
        return (bottle, game)
    }
}
