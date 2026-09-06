//
//  Telemetry.swift
//  OpenBottle
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

/// OpenBottle has no analytics endpoint. These event types remain while setup
/// call sites are simplified, and `capture` deliberately does nothing.
enum Telemetry {
    enum InstallFailureReason: String {
        case tarballMissing = "tarball_missing"
        case extractFailed = "extract_failed"
        case verifyFailed = "verify_failed"
        case downloadFailed = "download_failed"
        case runtimeIncomplete = "runtime_incomplete"
    }

    enum Event {
        case runtimeInstallStarted
        case runtimeInstallSucceeded
        case runtimeInstallFailed(reason: InstallFailureReason)
        case firstBottleCreated
        case firstProgramLaunchAttempted
    }

    static func capture(_: Event) {}
}
