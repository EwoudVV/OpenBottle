//
//  LibraryView+Runtime.swift
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

import SwiftUI
import WhiskyKit

extension LibraryView {
    var runtimeMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if runtimeSlots.isEmpty {
                    Text("runtime.slots.none")
                } else {
                    ForEach(runtimeSlots) { slot in
                        Button {
                            selectRuntime(slot)
                        } label: {
                            HStack {
                                Text(verbatim: runtimeLabel(slot))
                                if selectedRuntimeSlotID == slot.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(runtimeTitle, systemImage: "shippingbox")
            }
            .help("runtime.slots.help")
            .accessibilityIdentifier("library.runtime")
        }
    }

    func loadRuntimeSlots() {
        let manager = RuntimeSlotManager.live()
        do {
            runtimeSlots = try manager.slots()
            selectedRuntimeSlotID = try manager.defaultSlot()?.id
        } catch {
            model.launchError = error.localizedDescription
        }
    }

    private var runtimeTitle: String {
        guard let selected = runtimeSlots.first(where: { $0.id == selectedRuntimeSlotID }) else {
            return WhiskyWineInstaller.isWhiskyWineInstalled()
                ? String(localized: "runtime.slots.legacy")
                : String(localized: "runtime.slots.none")
        }
        return String(
            format: String(localized: "runtime.slots.current %@"),
            selected.manifest.runtimeVersion
        )
    }

    private func runtimeLabel(_ slot: RuntimeSlot) -> String {
        let channel = slot.manifest.channel.rawValue.capitalized
        return "\(slot.manifest.runtimeVersion) · \(channel)"
    }

    private func selectRuntime(_ slot: RuntimeSlot) {
        do {
            try RuntimeSlotManager.live().select(slotID: slot.id, channel: .stable)
            selectedRuntimeSlotID = slot.id
        } catch {
            model.launchError = error.localizedDescription
        }
    }
}
