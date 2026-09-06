// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import TsuyomiProtocol

/// Non-secret user preferences. Credentials, cookies, and reading positions never live here.
@MainActor
public final class AppPreferences: ObservableObject {
    @Published public private(set) var colorScheme: ColorSchemePreference
    @Published public private(set) var library: LibraryPresentationPreferences
    @Published public private(set) var reader: ReaderSettings
    @Published public private(set) var lastAppliedImportDigest: String?

    private let defaults: UserDefaults

    public static let suiteName = "org.tsuyomi.ios"

    public init(defaults: UserDefaults = UserDefaults(suiteName: AppPreferences.suiteName) ?? .standard) {
        self.defaults = defaults
        self.colorScheme = defaults.string(forKey: Key.colorScheme)
            .flatMap(ColorSchemePreference.init(rawValue:)) ?? .system
        self.library = LibraryPresentationPreferences(
            shortcutOrder: LibraryPresentationPreferences.sanitized(
                defaults.stringArray(forKey: Key.shortcutOrder) ?? []
            ),
            shortcutLocked: defaults.bool(forKey: Key.shortcutLocked),
            hiddenSystemNodes: LibraryPresentationPreferences.sanitized(
                defaults.stringArray(forKey: Key.hiddenSystemNodes) ?? []
            )
        )
        self.reader = AppPreferences.readReaderSettings(defaults)
        self.lastAppliedImportDigest = defaults.string(forKey: Key.lastAppliedImportDigest)
    }

    public func setColorScheme(_ value: ColorSchemePreference) {
        colorScheme = value
        defaults.set(value.rawValue, forKey: Key.colorScheme)
    }

    public func setShortcutOrder(_ order: [String]) {
        let sanitized = LibraryPresentationPreferences.sanitized(order)
        library.shortcutOrder = sanitized
        defaults.set(sanitized, forKey: Key.shortcutOrder)
    }

    public func setShortcutLocked(_ locked: Bool) {
        library.shortcutLocked = locked
        defaults.set(locked, forKey: Key.shortcutLocked)
    }

    /// Hiding a system node only removes an entry point; the books it would list stay on the shelf.
    public func setHiddenSystemNodes(_ nodes: [String]) {
        let sanitized = LibraryPresentationPreferences.sanitized(nodes)
        library.hiddenSystemNodes = sanitized
        defaults.set(sanitized, forKey: Key.hiddenSystemNodes)
    }

    public func setReader(_ settings: ReaderSettings) {
        reader = settings
        defaults.set(settings.fontSize, forKey: Key.readerFontSize)
        defaults.set(settings.lineHeight, forKey: Key.readerLineHeight)
        defaults.set(settings.horizontalMargin, forKey: Key.readerHorizontalMargin)
        defaults.set(settings.paragraphSpacing, forKey: Key.readerParagraphSpacing)
        defaults.set(settings.flow.rawValue, forKey: Key.readerFlow)
        defaults.set(settings.theme.rawValue, forKey: Key.readerTheme)
        defaults.set(settings.pageTransition.rawValue, forKey: Key.readerPageTransition)
        defaults.set(settings.lockPortrait, forKey: Key.readerLockPortrait)
        defaults.set(settings.progressVisible, forKey: Key.readerProgressVisible)
        defaults.set(settings.keepAwake, forKey: Key.readerKeepAwake)
    }

    /// The exportable subset of the reader settings, in `tsuyomi-transfer` vocabulary.
    public var portableReader: PortableReaderPreferences {
        PortableReaderPreferences(
            flow: reader.flow == .scroll ? "scroll" : "paged",
            fontScale: reader.fontSize / 18.0,
            lineHeight: reader.lineHeight,
            theme: reader.theme.rawValue
        )
    }

    /// Applies an imported preference patch and records the plan digest that produced it, so a
    /// replayed import cannot silently reapply the same patch twice.
    public func applyImported(_ preferences: PortableReaderPreferences?, digest: String) {
        if let preferences {
            var updated = reader
            switch preferences.flow {
            case "scroll": updated.flow = .scroll
            case "paged": updated.flow = .paged
            default: break
            }
            if let fontScale = preferences.fontScale, (0.5...3.0).contains(fontScale) {
                updated.fontSize = (18.0 * fontScale).clamped(to: ReaderSettings.fontSizeRange)
            }
            if let lineHeight = preferences.lineHeight, (0.8...3.0).contains(lineHeight) {
                updated.lineHeight = lineHeight.clamped(to: ReaderSettings.lineHeightRange)
            }
            if let theme = preferences.theme, let parsed = ReaderTheme(rawValue: theme) {
                updated.theme = parsed
            }
            setReader(updated)
        }
        lastAppliedImportDigest = digest
        defaults.set(digest, forKey: Key.lastAppliedImportDigest)
    }

    private static func readReaderSettings(_ defaults: UserDefaults) -> ReaderSettings {
        let stored = ReaderSettings()
        return ReaderSettings(
            fontSize: defaults.object(forKey: Key.readerFontSize) as? Double ?? stored.fontSize,
            lineHeight: defaults.object(forKey: Key.readerLineHeight) as? Double ?? stored.lineHeight,
            horizontalMargin: defaults.object(forKey: Key.readerHorizontalMargin) as? Double
                ?? stored.horizontalMargin,
            paragraphSpacing: defaults.object(forKey: Key.readerParagraphSpacing) as? Double
                ?? stored.paragraphSpacing,
            flow: defaults.string(forKey: Key.readerFlow).flatMap(ReaderPresentation.init(rawValue:)) ?? stored.flow,
            theme: defaults.string(forKey: Key.readerTheme).flatMap(ReaderTheme.init(rawValue:)) ?? stored.theme,
            pageTransition: defaults.string(forKey: Key.readerPageTransition)
                .flatMap(ReaderPageTransition.init(rawValue:)) ?? stored.pageTransition,
            lockPortrait: defaults.object(forKey: Key.readerLockPortrait) as? Bool ?? stored.lockPortrait,
            progressVisible: defaults.object(forKey: Key.readerProgressVisible) as? Bool ?? stored.progressVisible,
            keepAwake: defaults.object(forKey: Key.readerKeepAwake) as? Bool ?? stored.keepAwake
        )
    }

    private enum Key {
        static let colorScheme = "color_scheme"
        static let shortcutOrder = "library_shortcut_order"
        static let shortcutLocked = "library_shortcut_locked"
        static let hiddenSystemNodes = "library_hidden_system_nodes"
        static let readerFontSize = "reader_font_size"
        static let readerLineHeight = "reader_line_height"
        static let readerHorizontalMargin = "reader_horizontal_margin"
        static let readerParagraphSpacing = "reader_paragraph_spacing"
        static let readerFlow = "reader_flow"
        static let readerTheme = "reader_theme"
        static let readerPageTransition = "reader_page_transition"
        static let readerLockPortrait = "reader_lock_portrait"
        static let readerProgressVisible = "reader_progress_visible"
        static let readerKeepAwake = "reader_keep_awake"
        static let lastAppliedImportDigest = "last_applied_import_digest"
    }
}
