// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Reader surface palettes. They are colour-only: switching one never changes text metrics, so a
/// theme change must not repaginate.
public enum TsuyomiReaderPalette: String, Sendable, CaseIterable {
    case paper
    case warmGray
    case nightInk
    case black
    case inkGreen

    public var background: Color {
        switch self {
        case .paper: return Color(red: 0.98, green: 0.97, blue: 0.94)
        case .warmGray: return Color(red: 0.91, green: 0.89, blue: 0.86)
        case .nightInk: return Color(red: 0.09, green: 0.10, blue: 0.12)
        case .black: return .black
        case .inkGreen: return Color(red: 0.80, green: 0.85, blue: 0.78)
        }
    }

    public var foreground: Color {
        switch self {
        case .paper: return Color(red: 0.13, green: 0.12, blue: 0.11)
        case .warmGray: return Color(red: 0.16, green: 0.15, blue: 0.14)
        case .nightInk: return Color(red: 0.80, green: 0.81, blue: 0.84)
        case .black: return Color(white: 0.72)
        case .inkGreen: return Color(red: 0.11, green: 0.16, blue: 0.11)
        }
    }

    public var secondary: Color { foreground.opacity(0.62) }

    public var label: LocalizedStringKey {
        switch self {
        case .paper: return "阅读主题·纸色"
        case .warmGray: return "阅读主题·暖灰"
        case .nightInk: return "阅读主题·夜墨"
        case .black: return "阅读主题·纯黑"
        case .inkGreen: return "阅读主题·护眼绿"
        }
    }
}

/// Semantic colour and type tokens. Everything else in the app refers to these names rather than to
/// literal colours, so light and dark stay consistent and Dynamic Type is respected everywhere.
public enum TsuyomiTheme {
    public enum Palette {
        public static let surface = Color(.systemBackground)
        public static let raisedSurface = Color(.secondarySystemBackground)
        public static let groupedSurface = Color(.systemGroupedBackground)
        public static let primaryText = Color(.label)
        public static let secondaryText = Color(.secondaryLabel)
        public static let tertiaryText = Color(.tertiaryLabel)
        public static let separator = Color(.separator)
        public static let accent = Color.accentColor
        public static let warning = Color(.systemOrange)
        public static let danger = Color(.systemRed)
        public static let success = Color(.systemGreen)
    }

    public enum Typography {
        public static let screenTitle = Font.largeTitle.weight(.semibold)
        public static let sectionTitle = Font.headline
        public static let body = Font.body
        public static let supporting = Font.subheadline
        public static let caption = Font.caption
        public static let badge = Font.caption2.weight(.semibold)
    }

    public enum Metrics {
        public static let gutter: CGFloat = 16
        public static let tightGutter: CGFloat = 8
        public static let cornerRadius: CGFloat = 12
        /// The smallest reliably tappable target; every interactive affordance uses at least this.
        public static let minimumTouchTarget: CGFloat = 44
        public static let coverAspectRatio: CGFloat = 2.0 / 3.0
    }
}
