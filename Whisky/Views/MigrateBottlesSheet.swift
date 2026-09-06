//
//  MigrateBottlesSheet.swift
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

/// Copies bottles from an existing Whisky installation into OpenBottle's private storage.
struct MigrateBottlesSheet: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row] = []
    @State private var didLoad = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importedCount = 0

    private struct Row: Identifiable {
        let bottle: LegacyBottleImport.DiscoveredBottle
        var isSelected: Bool
        var id: URL {
            bottle.url
        }
    }

    private var selectedCount: Int {
        rows.filter(\.isSelected).count
    }

    private var allSelected: Bool {
        !rows.isEmpty && rows.allSatisfy(\.isSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 420)
        .onAppear(perform: loadIfNeeded)
        .interactiveDismissDisabled(isImporting)
        .alert("Couldn't import bottles", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import from Whisky")
                .font(.headline)
            Text(
                """
                OpenBottle makes and verifies its own copy. Your Whisky bottles stay where they are \
                and Whisky keeps working.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Whisky bottles were found.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach($rows) { $row in
                    Toggle(isOn: $row.isSelected) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.bottle.name)
                            Text(row.bottle.url.path(percentEncoded: false))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(row.bottle.sourceBundleIdentifier)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if isImporting {
                ProgressView(value: Double(importedCount), total: Double(max(selectedCount, 1)))
                    .frame(width: 120)
            }
            if !rows.isEmpty {
                Button(allSelected ? "Deselect All" : "Select All", action: toggleAll)
                    .disabled(isImporting)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isImporting)
            Button("Copy Selected") {
                Task { await importSelected() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0 || isImporting)
        }
        .padding()
    }

    private func toggleAll() {
        let target = !allSelected
        for index in rows.indices {
            rows[index].isSelected = target
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        rows = LegacyBottleImport
            .allImportableBottles(existingPaths: bottleVM.bottlesList.paths)
            .map { Row(bottle: $0, isSelected: true) }
    }

    private func importSelected() async {
        isImporting = true
        importedCount = 0
        defer { isImporting = false }
        var imported: [URL] = []
        do {
            for row in rows where row.isSelected {
                let source = row.bottle.url
                let result = try await Task.detached(priority: .userInitiated) {
                    try BottleImporter.copy(
                        bottleAt: source,
                        to: BottleData.defaultBottleDir
                    )
                }.value
                imported.append(result.bottleURL)
                importedCount += 1
            }
            let existing = bottleVM.bottlesList.paths
            bottleVM.bottlesList.paths = existing + imported.filter { !existing.contains($0) }
            bottleVM.loadBottles()
            dismiss()
        } catch {
            let existing = bottleVM.bottlesList.paths
            bottleVM.bottlesList.paths = existing + imported.filter { !existing.contains($0) }
            bottleVM.loadBottles()
            importError = error.localizedDescription
        }
    }
}
