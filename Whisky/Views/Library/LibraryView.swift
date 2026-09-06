//
//  LibraryView.swift
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// Everything worth launching, across every bottle, most recently played first.
///
/// This is the home screen because it is the thing people open Whisky to do. A
/// bottle is a Wine prefix, which is an implementation detail of running a
/// Windows program on a Mac, and it only earns space on screen once there is
/// more than one of them.
///
/// Entries come from ``LibraryCatalogue``, so Steam games sit beside pinned
/// programs and a future launcher needs no change here.
struct LibraryView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var selectedBottle: URL?
    @Binding var openedFileURL: URL?
    /// Toggled by the toolbar's refresh button. Folded into the reload trigger
    /// because the bottle list is unchanged by a refresh, so watching only that
    /// left the button spinning without rebuilding anything.
    @Binding var refresh: Bool

    @AppStorage("librarySort") private var sort: LibrarySort = .recent

    @StateObject var model = LibraryModel()
    @State private var search: String = ""
    @State var runtimeSlots: [RuntimeSlot] = []
    @State var selectedRuntimeSlotID: String?

    private var bottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    private var visible: [LibraryRow] {
        guard !search.isEmpty else { return model.rows }
        return model.rows.filter { $0.item.name.localizedCaseInsensitiveContains(search) }
    }

    /// Every input that changes what the grid should contain. Pins live in
    /// bottle settings, so a program pinned in the bottle screen shows up here
    /// without a relaunch.
    private var reloadTrigger: String {
        let pins = bottles.flatMap { $0.settings.pins.map(\.name) }
        return (bottles.map(\.url.path) + pins + ["\(refresh)"]).joined(separator: "\u{1F}")
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("library.title")
        .searchable(text: $search, prompt: Text("library.search"))
        .toolbar {
            installButton
            runtimeMenu
            sortMenu
        }
        .toast($model.toast)
        .task(id: reloadTrigger) {
            await model.reload(bottles: bottles)
            loadRuntimeSlots()
        }
        .onChange(of: sort, initial: true) {
            model.sort = sort
        }
        .onDisappear {
            model.stopTracking()
        }
        .sheet(item: $model.restoreSheet) { sheet in
            LibrarySaveRestoreSheet(
                state: sheet,
                isRestoring: model.restoringEntryIDs.contains(sheet.row.id)
            ) { snapshot in
                Task { await model.restore(snapshot, from: sheet, bottles: bottles) }
            }
        }
        .alert(
            "library.launch.failed",
            isPresented: Binding(
                get: { model.launchError != nil },
                set: { if !$0 { model.launchError = nil } }
            )
        ) {
            Button("button.ok") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
        .alert(
            "library.saves.failed",
            isPresented: Binding(
                get: { model.saveError != nil },
                set: { if !$0 { model.saveError = nil } }
            )
        ) {
            Button("button.ok") { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
        .alert(
            "Couldn’t export compatibility report",
            isPresented: Binding(
                get: { model.reportError != nil },
                set: { if !$0 { model.reportError = nil } }
            )
        ) {
            Button("button.ok") { model.reportError = nil }
        } message: {
            Text(model.reportError ?? "")
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("library.sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("library.sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("library.sort")
        }
    }

    private var installButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                chooseWindowsInstaller()
            } label: {
                Label("library.empty.install", systemImage: "plus.app")
            }
            .help("library.empty.install")
            .accessibilityIdentifier("library.install")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                // 180 rather than 220 so two columns fit at the window's own
                // minimum width, where the sidebar leaves about 330pt: one
                // column of landscape cards is a list with wasted space.
                columns: [GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 14)],
                spacing: 14
            ) {
                ForEach(visible) { row in
                    LibraryCard(
                        item: row.item,
                        bottleName: row.bottleName,
                        lastPlayed: row.lastPlayed,
                        state: model.state(for: row.item),
                        savePolicy: model.savePolicy(for: row),
                        launch: { model.launch(row, bottles: bottles) }
                    )
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
        }
        if model.canManageSaves(for: row) {
            Button {
                Task { await model.showRestorePoints(for: row, bottles: bottles) }
            } label: {
                Label("library.saves.menu", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.state(for: row.item) != .idle)
        }
        if case .steam = row.item.launch {
            Menu {
                savePolicyButton(.localOnly, for: row)
                savePolicyButton(.cloudAllowed, for: row)
            } label: {
                Label("library.saves.policy", systemImage: "externaldrive.badge.icloud")
            }
            .disabled(model.state(for: row.item) != .idle)
        }
        Button {
            Task { await model.exportCompatibilityReport(for: row, bottles: bottles) }
        } label: {
            Label("Export compatibility report…", systemImage: "doc.badge.arrow.up")
        }
        Divider()
        if case let .program(url) = row.item.launch {
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("library.card.unpin", role: .destructive) { unpin(url, in: row.item.bottleURL) }
        }
        // Per-program settings live inside the bottle's own navigation stack,
        // which the library cannot push onto, so this is as close as the menu
        // gets without a deep link into it.
        Button("library.card.configure") {
            selectedBottle = row.item.bottleURL
        }
    }

    private func savePolicyButton(
        _ policy: GameSavePolicy,
        for row: LibraryRow
    ) -> some View {
        let selected = model.savePolicy(for: row) == policy
        let title = policy == .localOnly
            ? LocalizedStringKey("library.saves.localOnly")
            : LocalizedStringKey("library.saves.cloudAllowed")
        return Button {
            Task { await model.setSavePolicy(policy, for: row) }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: selected ? "checkmark" : "circle")
            }
        }
    }

    private func unpin(_ url: URL, in bottleURL: URL) {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }) else { return }
        bottle.settings.pins.removeAll { $0.url == url }
        if let program = bottle.programs.first(where: { $0.url == url }) {
            program.pinned = false
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.noPrograms")
        } actions: {
            Button("library.empty.install") {
                chooseWindowsInstaller()
            }
            .buttonStyle(.borderedProminent)
            if let first = bottles.first {
                Button("library.empty.advanced") { selectedBottle = first.url }
            }
        }
    }

    private func chooseWindowsInstaller() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.exe,
            UTType(exportedAs: "com.microsoft.msi-installer"),
            UTType(exportedAs: "com.microsoft.msix-package"),
            UTType(exportedAs: "com.microsoft.appx-package")
        ]
        panel.begin { result in
            if result == .OK {
                openedFileURL = panel.urls.first
            }
        }
    }
}

private struct LibrarySaveRestoreSheet: View {
    let state: LibraryRestoreSheet
    let isRestoring: Bool
    let restore: (SaveSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    init(
        state: LibraryRestoreSheet,
        isRestoring: Bool,
        restore: @escaping (SaveSnapshot) -> Void
    ) {
        self.state = state
        self.isRestoring = isRestoring
        self.restore = restore
        _selection = State(initialValue: state.inventory.verified.first?.manifest.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("library.saves.title")
                    .font(.title2.bold())
                Text(state.row.item.name)
                    .font(.headline)
                Text("library.saves.description")
                    .foregroundStyle(.secondary)
            }

            if !state.inventory.invalidSnapshotIDs.isEmpty {
                Label("library.saves.invalid", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if state.inventory.verified.isEmpty {
                ContentUnavailableView(
                    "library.saves.empty",
                    systemImage: "clock.badge.questionmark",
                    description: Text("library.saves.empty.description")
                )
            } else {
                restorePointList
            }

            HStack {
                Spacer()
                Button("button.cancel") { dismiss() }
                    .disabled(isRestoring)
                Button {
                    if let selectedSnapshot {
                        restore(selectedSnapshot)
                    }
                } label: {
                    if isRestoring {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("library.saves.restore")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSnapshot == nil || isRestoring)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("library.saves.restore")
            }
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 420)
        .interactiveDismissDisabled(isRestoring)
        .accessibilityIdentifier("library.saves.sheet")
    }

    private var restorePointList: some View {
        List(state.inventory.verified, id: \.manifest.id, selection: $selection) { snapshot in
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text(snapshotSize(snapshot), format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .tag(snapshot.manifest.id)
        }
        .accessibilityIdentifier("library.saves.list")
    }

    private var selectedSnapshot: SaveSnapshot? {
        state.inventory.verified.first { $0.manifest.id == selection }
    }

    private func snapshotSize(_ snapshot: SaveSnapshot) -> Int64 {
        snapshot.manifest.files.reduce(0) { $0 + $1.byteCount }
    }
}
