// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

/// The execution discipline the port is graded against, enforced instead of remembered. Every rule
/// here is one a reviewer would otherwise have to re-check by hand on each change.
final class RepositoryHygieneTests: XCTestCase {
    private static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url
    }()

    /// This file necessarily contains the patterns it looks for.
    private static let selfName = "RepositoryHygieneTests.swift"

    private func swiftFiles() throws -> [URL] {
        var files: [URL] = []
        for directory in ["Sources", "Tests"] {
            let base = RepositoryHygieneTests.root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let path as String in walker where path.hasSuffix(".swift") {
                guard !path.hasSuffix(RepositoryHygieneTests.selfName) else { continue }
                files.append(base.appendingPathComponent(path))
            }
        }
        XCTAssertGreaterThan(files.count, 50, "the walk found suspiciously few Swift files")
        return files
    }

    func testEverySwiftFileCarriesAnSpdxHeader() throws {
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(
                text.hasPrefix("// SPDX-License-Identifier: AGPL-3.0-only"),
                "missing SPDX header: \(file.lastPathComponent)"
            )
        }
    }

    func testNoFileExceedsTheLineBudget() throws {
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertLessThanOrEqual(lines.count, 400, "\(file.lastPathComponent) is \(lines.count) lines")
        }
    }

    func testNoUnfinishedOrSuppressedCode() throws {
        let forbidden = ["TODO", "FIXME", "@unchecked", "try" + "!", "swiftlint:disable", "#if false"]
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden {
                XCTAssertFalse(text.contains(pattern), "\(file.lastPathComponent) contains \(pattern)")
            }
        }
    }

    /// The deployment target is iOS 16.4; these are all iOS 17 or later and must not appear even
    /// behind an availability check, because the design is required to work without them.
    func testNoApisAboveTheDeploymentTarget() throws {
        let forbidden = [
            "@Observable", "SwiftData", "ContentUnavailableView", "scrollTargetBehavior",
            "scrollPosition", "sensoryFeedback", "TipKit", ".snappy", ".bouncy", ".smooth"
        ]
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden {
                XCTAssertFalse(text.contains(pattern), "\(file.lastPathComponent) uses \(pattern)")
            }
        }
    }

    /// E-ink is deleted, not disabled: no symbol may survive that would let it be reintroduced by
    /// flipping a flag.
    func testNoInkScreenSymbolsSurvive() throws {
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in ["EINK", "eInk", "DisplayProfile"] {
                XCTAssertFalse(text.contains(pattern), "\(file.lastPathComponent) mentions \(pattern)")
            }
        }
    }

    func testNoKotlinOrAndroidTreeIsCommitted() throws {
        let listed = try? FileManager.default.contentsOfDirectory(atPath: RepositoryHygieneTests.root.path)
        XCTAssertFalse(listed?.contains("Tsuyomi-main") == true && isTracked("Tsuyomi-main"))
        for directory in ["Sources", "Tests"] {
            let base = RepositoryHygieneTests.root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let path as String in walker {
                XCTAssertFalse(path.hasSuffix(".kt"), "Kotlin file committed: \(path)")
            }
        }
    }

    /// `Tsuyomi-main` may sit next to the sources as a read-only reference checkout, but must never be
    /// tracked; the port has to stand on the protocol contracts alone.
    private func isTracked(_ path: String) -> Bool {
        let ignore = RepositoryHygieneTests.root.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: ignore, encoding: .utf8) else { return true }
        return !text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "\(path)/" }
    }
}
