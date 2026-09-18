// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import UIKit

/// The colours one theme draws its page in under one appearance. Both the SwiftUI chrome and the
/// TextKit drawing surface read it, so a theme is colour-only by construction: nothing here can
/// change text metrics, and a theme switch therefore never repaginates.
public struct ReaderPalette {
    public let backgroundColor: UIColor
    public let foregroundColor: UIColor
    /// How much heavier than its face the ink is drawn, in the unit `NSAttributedString.Key.strokeWidth`
    /// takes: a percentage of the point size, negative for fill-and-stroke. A heavier face would have
    /// wider advances and move every page boundary; a stroke around the same glyphs moves none.
    public let inkStroke: CGFloat

    public var background: Color { Color(uiColor: backgroundColor) }
    public var foreground: Color { Color(uiColor: foregroundColor) }

    /// The chrome drawn over a page is drawn in the page's own ink and paper, so a panel on a sepia
    /// page is sepia and a panel on a black page is black: the same two colours, at lesser weights.
    /// A control's face: the ink, faintly, over the paper.
    public var raisedSurface: Color { foreground.opacity(0.10) }
    /// A lifted surface's edge and a rule between controls.
    public var separator: Color { foreground.opacity(0.22) }
    /// The ink for a supporting line.
    public var secondaryForeground: Color { foreground.opacity(0.62) }
    /// The ink for a control that cannot be used right now.
    public var disabledForeground: Color { foreground.opacity(0.35) }
    /// What lifts a card off the page it shares a colour with: a breath of ink over the paper.
    public var lift: Color { foreground.opacity(0.05) }

    init(_ background: UIColor, _ foreground: UIColor, inkStroke: CGFloat = 0) {
        self.backgroundColor = background
        self.foregroundColor = foreground
        self.inkStroke = inkStroke
    }
}

public extension ReaderTheme {
    /// Two palettes, and the appearance in force says which.
    func palette(for scheme: ColorScheme) -> ReaderPalette {
        let dark = scheme == .dark
        switch self {
        case .original:
            return dark
                ? ReaderPalette(.black, UIColor(white: 0.86, alpha: 1))
                : ReaderPalette(.white, UIColor(white: 0.11, alpha: 1))
        case .quiet:
            return dark
                ? ReaderPalette(UIColor(white: 0.17, alpha: 1), UIColor(white: 0.80, alpha: 1))
                : ReaderPalette(UIColor(white: 0.91, alpha: 1), UIColor(white: 0.22, alpha: 1))
        case .paper:
            return dark
                ? ReaderPalette(rgb(0.16, 0.15, 0.12), rgb(0.85, 0.81, 0.72))
                : ReaderPalette(rgb(0.98, 0.96, 0.90), rgb(0.24, 0.20, 0.15))
        case .bold:
            return dark
                ? ReaderPalette(.black, .white, inkStroke: -3)
                : ReaderPalette(.white, .black, inkStroke: -3)
        case .calm:
            return dark
                ? ReaderPalette(rgb(0.21, 0.17, 0.13), rgb(0.90, 0.83, 0.72))
                : ReaderPalette(rgb(0.95, 0.89, 0.80), rgb(0.33, 0.24, 0.17))
        case .focus:
            return dark
                ? ReaderPalette(rgb(0.11, 0.15, 0.14), rgb(0.78, 0.85, 0.81))
                : ReaderPalette(rgb(0.90, 0.93, 0.90), rgb(0.13, 0.20, 0.17))
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .original: return "原始"
        case .quiet: return "安静"
        case .paper: return "纸张"
        case .bold: return "粗体"
        case .calm: return "平静"
        case .focus: return "专注"
        }
    }
}

private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
    UIColor(red: red, green: green, blue: blue, alpha: 1)
}
