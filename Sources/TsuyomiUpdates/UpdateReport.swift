// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore

/// The words a report uses for what the store recorded. Reason tokens are mapped, never shown raw
/// unless they are the bounded `source-…` diagnostics the host itself composed.
public enum UpdateReport {
    public static func label(_ state: UpdateSessionState) -> String {
        switch state {
        case .queued: return "排队中"
        case .running: return "正在检查"
        case .completed: return "已完成"
        case .partial: return "部分完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    public static func label(_ state: UpdateItemState) -> String {
        switch state {
        case .pending: return "待检查"
        case .unchanged: return "无更新"
        case .updated: return "有更新"
        case .skipped: return "已跳过"
        case .unavailable: return "暂不可用"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    /// A reason as the reader should read it. Unknown tokens are shown only when they are the
    /// host's own diagnostics, which by construction carry no page text.
    public static func reason(_ token: String?) -> String? {
        guard let token else { return nil }
        switch token {
        case "excluded": return "已排除"
        case "ineligible": return "已不在书架或网站收藏"
        case "cancelled": return "已取消"
        case "source-unavailable": return "来源不可用"
        case "updates-not-supported": return "来源不支持更新检查"
        case "stale-source-lease": return "来源在检查期间发生变化"
        case "invalid-probe-result": return "检查结果与记录不符"
        case "source-failure": return "来源出错"
        default: break
        }
        if token.hasPrefix("source-session-required") { return "需要登录" }
        if token.hasPrefix("source-verification-required") { return "需要验证" }
        if token.hasPrefix("source-network") { return "网络问题" }
        if token.hasPrefix("prior-anchor") { return "目录已变化，需要重新建立基线" }
        if token.hasPrefix("identity-mismatch") || token.hasPrefix("invalid-chapter-evidence") || token.hasPrefix("duplicate-chapter-id") {
            return "来源返回的目录不可信"
        }
        return token.hasPrefix("source-") && UpdateProbeResult.isReason(token) ? token : nil
    }

    public static func summary(_ session: UpdateSessionSummary) -> String {
        "\(label(session.state)) · \(session.completed)/\(session.total) · 更新 \(session.updated) · 失败 \(session.failed)"
    }
}
