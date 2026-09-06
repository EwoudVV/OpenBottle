//
//  StreamingFileHash.swift
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

import CryptoKit
import Darwin
import Foundation

/// Hashes large files with one reusable buffer and without filling the unified file cache.
enum StreamingFileHash {
    static let chunkSize = 1_048_576

    static func sha256(of url: URL) throws -> String {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { _ = Darwin.close(descriptor) }

        // A bottle import reads the same large tree three times. Caching tens of
        // gigabytes of game assets provides no reuse and can force the machine
        // into swap, so ask Darwin to discard these sequential read pages.
        _ = Darwin.fcntl(descriptor, F_NOCACHE, 1)

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw posixError()
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: bytes.baseAddress,
                    count: count
                ))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
