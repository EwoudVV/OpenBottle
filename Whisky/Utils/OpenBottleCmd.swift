//
//  OpenBottleCmd.swift
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
import Foundation
import WhiskyKit

class OpenBottleCmd {
    static func install() async {
        let openBottleCmdURL = Bundle.main.url(
            forResource: ProductIdentity.commandExecutable,
            withExtension: nil
        )

        if let openBottleCmdURL {
            // Use .esc to escape shell metacharacters and prevent command injection
            let script = """
            do shell script "ln -fs \(openBottleCmdURL.esc) /usr/local/bin/openbottle" with administrator privileges
            """

            var error: NSDictionary?
            // Use AppleScript because somehow in 2023 Apple doesn't have good privileged file ops APIs
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)

                if let error {
                    print(error)
                    if let description = error["NSAppleScriptErrorMessage"] as? String {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = String(localized: "alert.message")
                            alert.informativeText = String(localized: "alert.info")
                                + description
                            alert.alertStyle = .critical
                            alert.addButton(withTitle: String(localized: "button.ok"))
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }
}
