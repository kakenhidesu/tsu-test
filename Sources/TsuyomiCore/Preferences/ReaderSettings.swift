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

/// The page's colours, as a pair: every theme has a light and a dark palette, and the appearance in
/// force decides which is drawn. A theme is therefore never a choice between light and dark — that
/// choice is made once, for the app, and the theme follows it.
public enum ReaderTheme: String, Sendable, CaseIterable, Codable {
    case original
    case quiet
    case paper
    case bold
    case calm
    case focus

    /// The word a `tsuyomi-transfer` file uses for this theme. The file's schema fixes five words for
    /// five single palettes, so themes that have no word of their own travel as the nearest one.
    public var transferName: String {
        switch self {
        case .quiet: return "warmGray"
        case .focus: return "inkGreen"
        case .original, .paper, .bold, .calm: return "paper"
        }
    }

    /// The theme nearest to a transfer word. The dark words name a page that is dark under every
    /// appearance, which no theme here is, so they land on the theme whose dark palette they resemble.
    public init?(transferName: String) {
        switch transferName {
        case "paper": self = .paper
        case "warmGray", "nightInk": self = .quiet
        case "inkGreen": self = .focus
        case "black": self = .original
        default: return nil
        }
    }
}

/// Local reader typography and navigation state. It is host-only: nothing here is a durable reading
/// position, and none of it is exported by `tsuyomi-transfer`.
public struct ReaderSettings: Hashable, Sendable, Codable {
    public static let fontSizeRange: ClosedRange<Double> = 12...32
    /// The sizes a step lands on. The range above stays wider than the run so an imported scale can
    /// fall anywhere inside it; such a size is shown on, and stepped from, the nearest step.
    public static let fontSizeSteps: [Double] = [14, 16, 18, 20, 22, 24, 28, 32]
    public static let lineHeightRange: ClosedRange<Double> = 1.0...2.4
    public static let horizontalMarginRange: ClosedRange<Double> = 8...64
    public static let paragraphSpacingRange: ClosedRange<Double> = 0...32

    public var fontSize: Double
    public var lineHeight: Double
    public var horizontalMargin: Double
    public var paragraphSpacing: Double
    public var flow: ReaderPresentation
    public var theme: ReaderTheme
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
        theme: ReaderTheme = .original,
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
        self.theme = theme
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

public extension ReaderSettings {
    var fontSizeStep: Int {
        let steps = Self.fontSizeSteps
        return steps.indices.min { abs(steps[$0] - fontSize) < abs(steps[$1] - fontSize) } ?? 0
    }

    func canStepFontSize(_ delta: Int) -> Bool {
        Self.fontSizeSteps.indices.contains(fontSizeStep + delta)
    }

    mutating func stepFontSize(_ delta: Int) {
        guard canStepFontSize(delta) else { return }
        fontSize = Self.fontSizeSteps[fontSizeStep + delta]
    }
}
