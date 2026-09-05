// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The one place a screen's non-content state is drawn. Every screen uses it so "loading", "empty",
/// "offline", and "failed" look and behave identically, and so a failure always offers a retry.
public enum TsuyomiScreenState<Content> {
    case loading
    case empty(title: LocalizedStringKey, detail: LocalizedStringKey?)
    case offline(detail: LocalizedStringKey?)
    case failed(code: String, detail: LocalizedStringKey?)
    case content(Content)
}

public struct StateView<Content, Body: View>: View {
    private let state: TsuyomiScreenState<Content>
    private let retry: (() -> Void)?
    private let content: (Content) -> Body

    public init(
        _ state: TsuyomiScreenState<Content>,
        retry: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Content) -> Body
    ) {
        self.state = state
        self.retry = retry
        self.content = content
    }

    public var body: some View {
        switch state {
        case .loading:
            placeholder(
                symbol: "hourglass",
                title: "正在载入",
                detail: nil,
                showsProgress: true
            )
        case .empty(let title, let detail):
            placeholder(symbol: "tray", title: title, detail: detail, showsProgress: false)
        case .offline(let detail):
            placeholder(
                symbol: "wifi.slash",
                title: "当前离线",
                detail: detail ?? "只显示已缓存的内容。",
                showsProgress: false
            )
        case .failed(let code, let detail):
            failure(code: code, detail: detail)
        case .content(let value):
            content(value)
        }
    }

    private func placeholder(
        symbol: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey?,
        showsProgress: Bool
    ) -> some View {
        VStack(spacing: TsuyomiTheme.Metrics.gutter) {
            if showsProgress {
                ProgressView()
            } else {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(TsuyomiTheme.Typography.sectionTitle)
                .foregroundStyle(TsuyomiTheme.Palette.primaryText)
            if let detail {
                Text(detail)
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(TsuyomiTheme.Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// A failure shows only a stable diagnostic code; raw HTML, cookies, and JS stacks never reach
    /// the interface.
    private func failure(code: String, detail: LocalizedStringKey?) -> some View {
        VStack(spacing: TsuyomiTheme.Metrics.gutter) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(TsuyomiTheme.Palette.warning)
                .accessibilityHidden(true)
            Text("操作未完成")
                .font(TsuyomiTheme.Typography.sectionTitle)
            if let detail {
                Text(detail)
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Text(code)
                .font(TsuyomiTheme.Typography.caption.monospaced())
                .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                .textSelection(.enabled)
            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            }
        }
        .padding(TsuyomiTheme.Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
