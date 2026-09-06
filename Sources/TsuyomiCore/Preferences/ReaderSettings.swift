// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ColorSchemePreference: String, Sendable, CaseIterable, Codable {
    case system
    case light
    case dark
}

public enum ReaderPresentation: String, Sendable, CaseIterable, Codable {
    case scroll
    case paged
    case dualPage
}

/// How a page turn is drawn. Presentation only: none of these changes where a page ends, so a page
/// plan stays valid across a change and the reader does not repaginate.
public enum ReaderPageTransition: String, Sendable, CaseIterable, Codable {
    case slide
    case curl
    case immediate
}

/// The page's colours. It is not a reader setting of its own: there is one appearance choice in this
/// app and the page follows it, so this is derived from that choice rather than picked separately.
/// The full set survives because it is the vocabulary a `tsuyomi-transfer` file speaks.
public enum ReaderTheme: String, Sendable, CaseIterable, Codable {
    case paper
    case warmGray
    case nightInk
    case black
    case inkGreen
}

/// Local reader typography and navigation state. It is host-only: nothing here is a durable reading
/// position, and none of it is exported by `tsuyomi-transfer`.
public struct ReaderSettings: Hashable, Sendable, Codable {
    public static let fontSizeRange: ClosedRange<Double> = 12...32
    public static let lineHeightRange: ClosedRange<Double> = 1.0...2.4
    public static let horizontalMarginRange: ClosedRange<Double> = 8...64
    public static let paragraphSpacingRange: ClosedRange<Double> = 0...32

    public var fontSize: Double
    public var lineHeight: Double
    public var horizontalMargin: Double
    public var paragraphSpacing: Double
    public var flow: ReaderPresentation
    public var pageTransition: ReaderPageTransition
    public var lockPortrait: Bool
    public var progressVisible: Bool
    public var keepAwake: Bool

    public init(
        fontSize: Double = 18,
        lineHeight: Double = 1.6,
        horizontalMargin: Double = 24,
        paragraphSpacing: Double = 12,
        flow: ReaderPresentation = .paged,
        pageTransition: ReaderPageTransition = .slide,
        lockPortrait: Bool = false,
        progressVisible: Bool = true,
        keepAwake: Bool = true
    ) {
        self.fontSize = fontSize.clamped(to: Self.fontSizeRange)
        self.lineHeight = lineHeight.clamped(to: Self.lineHeightRange)
        self.horizontalMargin = horizontalMargin.clamped(to: Self.horizontalMarginRange)
        self.paragraphSpacing = paragraphSpacing.clamped(to: Self.paragraphSpacingRange)
        self.flow = flow
        self.pageTransition = pageTransition
        self.lockPortrait = lockPortrait
        self.progressVisible = progressVisible
        self.keepAwake = keepAwake
    }
}

public struct LibraryPresentationPreferences: Hashable, Sendable {
    public static let maximumShortcutCount = 256
    public static let maximumShortcutIdLength = 2304

    public var shortcutOrder: [String]
    public var shortcutLocked: Bool
    public var hiddenSystemNodes: [String]

    public init(
        shortcutOrder: [String] = [],
        shortcutLocked: Bool = false,
        hiddenSystemNodes: [String] = []
    ) {
        self.shortcutOrder = shortcutOrder
        self.shortcutLocked = shortcutLocked
        self.hiddenSystemNodes = hiddenSystemNodes
    }

    static func sanitized(_ order: [String]) -> [String] {
        var seen = Set<String>()
        return order
            .filter { !$0.isEmpty && $0.count <= maximumShortcutIdLength && seen.insert($0).inserted }
            .prefix(maximumShortcutCount)
            .map { $0 }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        isFinite ? Swift.min(Swift.max(self, range.lowerBound), range.upperBound) : range.lowerBound
    }
}

public extension ReaderTheme {
    var isDark: Bool { self == .nightInk || self == .black }

    /// The page under an app appearance. `system` reads as light here because this is the value a
    /// transfer file carries, and a file cannot say "whatever that device was set to".
    static func reading(under appearance: ColorSchemePreference) -> ReaderTheme {
        appearance == .dark ? .nightInk : .paper
    }
}
