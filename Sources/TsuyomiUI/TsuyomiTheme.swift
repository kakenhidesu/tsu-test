// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

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
