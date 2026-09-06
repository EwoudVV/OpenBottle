//
//  Program+Terminal.swift
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

import AppKit
import Foundation
import os.log

public extension Program {
    /// Generates the underlying Wine command for inspection or manual use.
    func generateTerminalCommand(args: String? = nil) -> String {
        Wine.generateRunCommand(
            at: url,
            bottle: bottle,
            args: args ?? settings.arguments,
            environment: generateEnvironment()
        )
    }

    /// Generates the underlying Wine command while preserving argument boundaries.
    func generateTerminalCommand(args: [String]) -> String {
        let escapedArgs = args.map(\.esc).joined(separator: " ")
        return Wine.generateRunCommand(
            at: url,
            bottle: bottle,
            args: escapedArgs,
            environment: generateEnvironment(),
            preEscaped: true
        )
    }

    /// Opens a terminal whose command still enters OpenBottle's safe launch path.
    func runInTerminal() {
        let commandURL = bundledCommandURL() ?? URL(
            filePath: "/Applications/OpenBottle.app/Contents/Resources/OpenBottleCmd"
        )
        guard FileManager.default.isExecutableFile(atPath: commandURL.path(percentEncoded: false)) else {
            showTerminalRunError(message: "OpenBottleCmd is missing from the app")
            return
        }
        let programArguments = settings.arguments.split { $0.isWhitespace }.map(String.init)
        let command = ShellQuoting.commandLine(
            [
                commandURL.path(percentEncoded: false),
                "run",
                bottle.settings.name,
                url.path(percentEncoded: false),
                "--"
            ] + programArguments
        )
        writeAndOpenTerminalScript(command)
    }

    private func bundledCommandURL() -> URL? {
        Bundle.main.url(
            forResource: ProductIdentity.commandExecutable,
            withExtension: nil
        )
    }

    private func writeAndOpenTerminalScript(_ command: String) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openbottle-run-\(UUID().uuidString).sh")
        do {
            try "#!/bin/bash\n\(command)\n".write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            Logger.wineKit.error("Failed to write terminal script: \(error)")
            return
        }

        TempFileTracker.shared.register(file: scriptURL)
        let appleScript = TerminalApp.preferred.generateAppleScript(for: scriptURL.path)
        Task {
            var error: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
            if let description = error?["NSAppleScriptErrorMessage"] as? String {
                showTerminalRunError(message: description)
            }
            try? await Task.sleep(for: .seconds(5))
            await TempFileTracker.shared.cleanupWithRetry(file: scriptURL)
        }
    }

    @MainActor
    private func showTerminalRunError(message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.message")
        alert.informativeText = String(localized: "alert.info")
            + " \(url.lastPathComponent): \(message)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "button.ok"))
        alert.runModal()
    }
}
