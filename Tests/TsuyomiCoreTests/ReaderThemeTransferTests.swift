// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

/// The transfer file speaks five theme words fixed by its schema; the reader has six themes of two
/// palettes each. A file must never be written that the schema rejects, and a word must never be
/// read that throws the import away.
final class ReaderThemeTransferTests: XCTestCase {
    private let suite = "org.tsuyomi.tests.reader-theme"

    func testEveryThemeExportsAWordTheSchemaAllows() {
        for theme in ReaderTheme.allCases {
            XCTAssertTrue(PortableReaderPreferences.themes.contains(theme.transferName), "\(theme)")
        }
    }

    func testEveryTransferWordLandsOnAThemeAndAnyOtherIsIgnored() {
        for word in PortableReaderPreferences.themes {
            XCTAssertNotNil(ReaderTheme(transferName: word), word)
        }
        XCTAssertEqual(ReaderTheme(transferName: "nightInk"), .quiet)
        XCTAssertNil(ReaderTheme(transferName: "sepia"))
    }

    @MainActor
    func testStoredAndImportedWordsFallBackInsteadOfThrowing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("inkGreen", forKey: "reader_theme")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.reader.theme, .focus)

        preferences.applyImported(PortableReaderPreferences(theme: "black"), digest: "one")
        XCTAssertEqual(preferences.reader.theme, .original)
        preferences.applyImported(PortableReaderPreferences(theme: "sepia"), digest: "two")
        XCTAssertEqual(preferences.reader.theme, .original)
        XCTAssertEqual(preferences.portableReader.theme, "paper")

        defaults.set("not-a-theme", forKey: "reader_theme")
        XCTAssertEqual(AppPreferences(defaults: defaults).reader.theme, .original)
    }

    func testTheDefaultSizeSitsOnTheThirdStep() {
        var settings = ReaderSettings()
        XCTAssertEqual(settings.fontSizeStep, 2)
        settings.fontSize = 13
        XCTAssertEqual(settings.fontSizeStep, 0)
        XCTAssertFalse(settings.canStepFontSize(-1))
        settings.stepFontSize(1)
        XCTAssertEqual(settings.fontSize, 16)
    }
}
