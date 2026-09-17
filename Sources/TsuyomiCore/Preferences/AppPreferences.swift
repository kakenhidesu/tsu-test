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
            ),
            websiteGroupingSources: Set(
                LibraryPresentationPreferences.sanitized(defaults.stringArray(forKey: Key.websiteGrouping) ?? [])
            ),
            tabPresentations: AppPreferences.readTabPresentations(defaults),
            showUpdatesOnly: defaults.bool(forKey: Key.showUpdatesOnly)
        )
        self.reader = AppPreferences.readReaderSettings(defaults)
        self.lastAppliedImportDigest = defaults.string(forKey: Key.lastAppliedImportDigest)
    }

    /// Set once the built-in repository and its publisher have been written, so that removing either
    /// afterwards is a decision that survives the next launch.
    public var officialRepositorySeeded: Bool {
        defaults.bool(forKey: Key.officialRepositorySeeded)
    }

    public func markOfficialRepositorySeeded() {
        defaults.set(true, forKey: Key.officialRepositorySeeded)
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

    public func setWebsiteGrouping(_ sourceId: String, enabled: Bool) {
        if enabled {
            library.websiteGroupingSources.insert(sourceId)
        } else {
            library.websiteGroupingSources.remove(sourceId)
        }
        defaults.set(
            library.websiteGroupingSources.sorted { CanonicalOrder.precedes($0, $1) },
            forKey: Key.websiteGrouping
        )
    }

    public func setTabPresentation(_ tab: String, _ presentation: LibraryTabPresentation) {
        library.tabPresentations[tab] = presentation
        if let data = try? JSONEncoder().encode(library.tabPresentations) {
            defaults.set(data, forKey: Key.tabPresentations)
        }
    }

    public func setShowUpdatesOnly(_ value: Bool) {
        library.showUpdatesOnly = value
        defaults.set(value, forKey: Key.showUpdatesOnly)
    }

    /// Forgets every interface choice — appearance, shelf presentation, reader typography — and
    /// nothing else: the source flow's restoration snapshot, the last import digest and the official
    /// repository seed are not interface and stay.
    public func resetInterfacePreferences() {
        for key in Key.interfaceKeys { defaults.removeObject(forKey: key) }
        colorScheme = .system
        library = LibraryPresentationPreferences()
        reader = ReaderSettings()
    }

    private static func readTabPresentations(_ defaults: UserDefaults) -> [String: LibraryTabPresentation] {
        guard let data = defaults.data(forKey: Key.tabPresentations),
              let decoded = try? JSONDecoder().decode([String: LibraryTabPresentation].self, from: data) else { return [:] }
        return decoded
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
            theme: reader.theme.transferName,
            horizontalMargin: reader.horizontalMargin.clamped(to: PortableReaderPreferences.horizontalMarginRange),
            paragraphSpacing: reader.paragraphSpacing.clamped(to: PortableReaderPreferences.paragraphSpacingRange),
            lockPortrait: reader.lockPortrait,
            progressVisible: reader.progressVisible,
            keepAwake: reader.keepAwake
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
            if let margin = preferences.horizontalMargin {
                updated.horizontalMargin = margin.clamped(to: ReaderSettings.horizontalMarginRange)
            }
            if let spacing = preferences.paragraphSpacing {
                updated.paragraphSpacing = spacing.clamped(to: ReaderSettings.paragraphSpacingRange)
            }
            preferences.lockPortrait.map { updated.lockPortrait = $0 }
            preferences.progressVisible.map { updated.progressVisible = $0 }
            preferences.keepAwake.map { updated.keepAwake = $0 }
            if let theme = preferences.theme, let parsed = ReaderTheme(transferName: theme) {
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
            /// The two-page spread is no longer offered on a phone; a stored choice of it reads as
            /// paged so the picker always shows the setting in force.
            flow: defaults.string(forKey: Key.readerFlow).flatMap(ReaderPresentation.init(rawValue:))
                .map { $0 == .dualPage ? .paged : $0 } ?? stored.flow,
            /// A value stored before the themes were paired is one of the transfer words, so the same
            /// reading serves both rather than a migration that would run once and then be dead.
            theme: defaults.string(forKey: Key.readerTheme)
                .flatMap { ReaderTheme(rawValue: $0) ?? ReaderTheme(transferName: $0) } ?? stored.theme,
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
        static let websiteGrouping = "library_website_grouping"
        static let tabPresentations = "library_tab_presentations_v1"
        static let showUpdatesOnly = "library_show_updates_only"
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
        static let officialRepositorySeeded = "official_repository_seeded"

        static let interfaceKeys = [
            colorScheme, shortcutOrder, shortcutLocked, hiddenSystemNodes, websiteGrouping, tabPresentations,
            showUpdatesOnly, readerFontSize, readerLineHeight, readerHorizontalMargin, readerParagraphSpacing,
            readerFlow, readerTheme, readerPageTransition, readerLockPortrait, readerProgressVisible, readerKeepAwake
        ]
    }
}
