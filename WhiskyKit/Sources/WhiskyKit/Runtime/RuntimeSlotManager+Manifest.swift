//
//  RuntimeSlotManager+Manifest.swift
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

struct RuntimeManifestInput {
    let id: String
    let channel: RuntimeChannel
    let version: String
    let runtimeInfo: WhiskyWineVersion
    let libraryURL: URL
    let sourceURL: URL?
    let archiveSHA256: String
    let date: Date
}

private struct RuntimeComponentSpec {
    let name: String
    let version: String?
    let license: String
    let source: String
    let path: String
}

extension RuntimeSlotManager {
    func makeManifest(_ input: RuntimeManifestInput) throws -> RuntimeSlotManifest {
        var specs = [RuntimeComponentSpec(
            name: "Wine",
            version: nil,
            license: "LGPL-2.1-or-later",
            source: "https://github.com/Gcenx/macOS_Wine_builds",
            path: "Wine/bin/wine64"
        )]
        var capabilities: Set<String> = ["wined3d", "x86_64-windows"]

        if hasComponent("DXVK/x64/d3d11.dll", libraryURL: input.libraryURL) {
            specs.append(RuntimeComponentSpec(
                name: "DXVK-macOS",
                version: input.runtimeInfo.dxvkVersion,
                license: "Zlib",
                source: "https://github.com/Gcenx/DXVK-macOS",
                path: "DXVK/x64/d3d11.dll"
            ))
            capabilities.insert("dxvk")
        }
        if hasComponent("DXMT/x64/d3d11.dll", libraryURL: input.libraryURL) {
            specs.append(RuntimeComponentSpec(
                name: "DXMT",
                version: input.runtimeInfo.dxmtVersion,
                license: input.runtimeInfo.dxmtVersion == "0.80" ? "MIT" : "LGPL-2.1-or-later",
                source: "https://github.com/3Shain/dxmt",
                path: "DXMT/x64/d3d11.dll"
            ))
            capabilities.insert("dxmt")
        }
        if WhiskyWineInstaller.isD3DMetalPresent(inLibraryFolder: input.libraryURL) {
            capabilities.insert("d3dmetal-user-supplied")
        }
        if input.runtimeInfo.gptkCapable == true {
            capabilities.insert("gptk-capable-wine")
        }

        return try RuntimeSlotManifest(
            id: input.id,
            channel: input.channel,
            runtimeVersion: input.version,
            createdAt: input.date,
            sourceURL: input.sourceURL,
            archiveSHA256: input.archiveSHA256,
            components: specs.map { try component($0, libraryURL: input.libraryURL) },
            capabilities: capabilities
        )
    }

    private func hasComponent(_ path: String, libraryURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: libraryURL.appending(path: path).path(percentEncoded: false)
        )
    }

    private func component(
        _ spec: RuntimeComponentSpec,
        libraryURL: URL
    ) throws -> RuntimeComponentManifest {
        let url = libraryURL.appending(path: spec.path)
        guard let sha256 = WhiskyWineInstaller.sha256(ofFileAt: url) else {
            throw RuntimeSlotError.componentChanged(spec.name)
        }
        return RuntimeComponentManifest(
            name: spec.name,
            version: spec.version,
            license: spec.license,
            sourceURL: URL(string: spec.source) ?? URL(fileURLWithPath: "/"),
            representativePath: spec.path,
            sha256: sha256
        )
    }
}
