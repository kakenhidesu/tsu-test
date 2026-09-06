// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import UIKit

/// The one colour table for reader themes. Both the SwiftUI chrome and the TextKit drawing surface
/// read it, so a theme is colour-only by construction: nothing here can change text metrics, and a
/// theme switch therefore never repaginates.
public extension ReaderTheme {
    var backgroundColor: UIColor {
        switch self {
        case .paper: return UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        case .warmGray: return UIColor(red: 0.91, green: 0.89, blue: 0.86, alpha: 1)
        case .nightInk: return UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        case .black: return .black
        case .inkGreen: return UIColor(red: 0.80, green: 0.85, blue: 0.78, alpha: 1)
        }
    }

    var foregroundColor: UIColor {
        switch self {
        case .paper: return UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1)
        case .warmGray: return UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
        case .nightInk: return UIColor(red: 0.80, green: 0.81, blue: 0.84, alpha: 1)
        case .black: return UIColor(white: 0.72, alpha: 1)
        case .inkGreen: return UIColor(red: 0.11, green: 0.16, blue: 0.11, alpha: 1)
        }
    }

    var background: Color { Color(uiColor: backgroundColor) }
    var foreground: Color { Color(uiColor: foregroundColor) }

    /// The page under the appearance actually in force, `system` already resolved. The reader has no
    /// colour setting of its own: it is light or dark because the app is.
    static func reading(under scheme: ColorScheme) -> ReaderTheme {
        scheme == .dark ? .nightInk : .paper
    }

    var label: LocalizedStringKey {
        switch self {
        case .paper: return "纸色"
        case .warmGray: return "暖灰"
        case .nightInk: return "夜墨"
        case .black: return "纯黑"
        case .inkGreen: return "护眼绿"
        }
    }
}
