// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiProtocol

/// What the reader can actually do about a source failure, for the codes where there is something to
/// do. One table rather than one per screen: the same code means the same thing wherever it surfaces,
/// and a second copy is how a book screen ends up saying it could not read the page when the site was
/// only asking to be verified.
public enum SourceFailureGuidance {
    public static func detail(for error: any Error, fallback: LocalizedStringKey) -> LocalizedStringKey {
        guard let failure = error as? SourceException else { return fallback }
        switch failure.code {
        case .sessionRequired: return "需要先在受控浏览器中登录。"
        case .verificationRequired: return "站点要求人工验证，请在受控浏览器中完成。"
        case .networkOffline: return "当前离线，只显示已缓存的内容。"
        default: return fallback
        }
    }
}
