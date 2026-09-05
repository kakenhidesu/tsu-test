// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

/// Fixtures are read in place from the read-only reference checkout; nothing is copied into this
/// repository (IOS_PORT_PROMPT §5).
enum ProtocolFixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url
            .appendingPathComponent("Tsuyomi-main")
            .appendingPathComponent("tsuyomi-protocol")
            .appendingPathComponent("fixtures")
    }()

    static func data(_ relativePath: String) throws -> Data {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(relativePath); check out Tsuyomi-main next to this repository")
        }
        return try Data(contentsOf: url)
    }

    static func jsonFiles(in directory: String) throws -> [String] {
        let url = root.appendingPathComponent(directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            throw XCTSkip("Missing fixture directory \(directory)")
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { "\(directory)/\($0)" }
    }
}
