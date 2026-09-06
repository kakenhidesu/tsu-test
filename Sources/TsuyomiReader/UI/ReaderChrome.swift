// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// What the chrome is allowed to ask the reader coordinator to do. Every control here has a real
/// handler; there is no disabled placeholder.
public struct ReaderChromeActions {
    public let onBack: () -> Void
    public let onPreviousChapter: (() -> Void)?
    public let onNextChapter: (() -> Void)?
    public let onOpenDirectory: () -> Void
    public let onOpenSettings: () -> Void
    public let onScrubBegin: () -> Void
    /// Takes a fraction of the chapter, 0 through 1 — not a page index. Passing an index is what made
    /// the old slider look broken: every drag past the first pixel resolved past the last page.
    public let onScrub: (Double) -> Void
    public let onScrubEnd: () -> Void

    public init(
        onBack: @escaping () -> Void,
        onPreviousChapter: (() -> Void)?,
        onNextChapter: (() -> Void)?,
        onOpenDirectory: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onScrubBegin: @escaping () -> Void,
        onScrub: @escaping (Double) -> Void,
        onScrubEnd: @escaping () -> Void
    ) {
        self.onBack = onBack
        self.onPreviousChapter = onPreviousChapter
        self.onNextChapter = onNextChapter
        self.onOpenDirectory = onOpenDirectory
        self.onOpenSettings = onOpenSettings
        self.onScrubBegin = onScrubBegin
        self.onScrub = onScrub
        self.onScrubEnd = onScrubEnd
    }
}

/// How much of the screen the chrome owns. The page is inset by this much so the running head and the
/// page number sit beside the text rather than on top of it.
public enum ReaderChromeMetrics {
    public static let headerHeight: CGFloat = 34
    public static let footerHeight: CGFloat = 34
}

/// Almost nothing, which is the point. Reading, the page carries only the chapter it belongs to and
/// the page number. A tap in the middle brings back the two controls there are — close, and a menu —
/// and the page number gains its total.
public struct ReaderChrome: View {
    private let chapterTitle: String
    private let pageIndex: Int
    private let pageCount: Int
    private let isVisible: Bool
    private let progressVisible: Bool
    private let actions: ReaderChromeActions
    @State private var isMenuOpen = false

    public init(
        chapterTitle: String,
        pageIndex: Int,
        pageCount: Int,
        isVisible: Bool,
        progressVisible: Bool,
        actions: ReaderChromeActions
    ) {
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.isVisible = isVisible
        self.progressVisible = progressVisible
        self.actions = actions
    }

    public var body: some View {
        ZStack {
            if isMenuOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { isMenuOpen = false }
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if isMenuOpen { panel }
                if isVisible, pageCount > 1 {
                    ReaderScrubber(
                        pageIndex: pageIndex,
                        pageCount: pageCount,
                        chapterTitle: chapterTitle,
                        onBegin: actions.onScrubBegin,
                        onScrub: actions.onScrub,
                        onEnd: actions.onScrubEnd
                    )
                    .padding(.bottom, TsuyomiTheme.Metrics.tightGutter)
                }
                footer
            }
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .animation(.default, value: isVisible)
        .animation(.default, value: isMenuOpen)
        .onChange(of: isVisible) { visible in
            if !visible { isMenuOpen = false }
        }
    }

    /// The chapter title sits where it does in a printed book — a running head — and stays there
    /// whether or not the controls are up, because it is part of the page, not a control.
    private var header: some View {
        ZStack {
            Text(chapterTitle)
                .font(TsuyomiTheme.Typography.caption)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, TsuyomiTheme.Metrics.minimumTouchTarget)
            if isVisible {
                HStack {
                    Spacer()
                    Button(action: actions.onBack) { CircularChromeLabel(symbol: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
        }
        .frame(height: ReaderChromeMetrics.headerHeight)
    }

    private var footer: some View {
        ZStack {
            if isVisible || progressVisible { pageIndicator }
            if isVisible {
                HStack {
                    Spacer()
                    Button { isMenuOpen.toggle() } label: { CircularChromeLabel(symbol: "ellipsis") }
                        .accessibilityLabel("更多")
                }
            }
        }
        .frame(height: ReaderChromeMetrics.footerHeight)
    }

    private var pageIndicator: some View {
        Text(isVisible ? "\(pageIndex + 1)/\(pageCount) 页" : "\(pageIndex + 1)")
            .font(TsuyomiTheme.Typography.caption)
            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            .padding(.horizontal, TsuyomiTheme.Metrics.minimumTouchTarget)
            .accessibilityLabel("第 \(pageIndex + 1) 页，共 \(pageCount) 页")
    }

    /// Rows, not a system menu: a menu cannot carry the progress that belongs beside 目录, and it
    /// dismisses itself on the way to a sheet, which reads as the panel flickering away.
    private var panel: some View {
        VStack(alignment: .trailing, spacing: TsuyomiTheme.Metrics.tightGutter) {
            VStack(spacing: 0) {
                panelRow(title: "目录", detail: "\(percentRead)%", symbol: "list.bullet") {
                    isMenuOpen = false
                    actions.onOpenDirectory()
                }
                Divider()
                panelRow(title: "主题与设置", detail: "大小", symbol: "textformat.size") {
                    isMenuOpen = false
                    actions.onOpenSettings()
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                if let previous = actions.onPreviousChapter {
                    Button {
                        isMenuOpen = false
                        previous()
                    } label: {
                        CircularChromeLabel(symbol: "backward.end")
                    }
                    .accessibilityLabel("上一章")
                }
                if let next = actions.onNextChapter {
                    Button {
                        isMenuOpen = false
                        next()
                    } label: {
                        CircularChromeLabel(symbol: "forward.end")
                    }
                    .accessibilityLabel("下一章")
                }
            }
        }
        .frame(maxWidth: 320, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, TsuyomiTheme.Metrics.tightGutter)
    }

    private func panelRow(
        title: LocalizedStringKey,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Text(title)
                    .font(TsuyomiTheme.Typography.body)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                Text(detail)
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
            }
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var percentRead: Int {
        guard pageCount > 1 else { return 100 }
        return Int((Double(pageIndex + 1) / Double(pageCount) * 100).rounded())
    }
}

/// A control that floats over the page rather than sitting in a bar: the page keeps its full height
/// whether the controls are up or not, so bringing them back never reflows a word of text.
struct CircularChromeLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TsuyomiTheme.Palette.primaryText)
            .frame(
                width: TsuyomiTheme.Metrics.minimumTouchTarget,
                height: TsuyomiTheme.Metrics.minimumTouchTarget
            )
            .background(.regularMaterial, in: Circle())
    }
}

/// The bar the reader drags to move through a chapter, and the only entry point to the preview
/// session: dragging shows a frozen preview of where it would land, and releasing performs the one
/// semantic navigation. While the finger is down a bubble names the chapter and the page, because a
/// bar that moves under a covered thumb says nothing about where it has got to.
struct ReaderScrubber: View {
    let pageIndex: Int
    let pageCount: Int
    let chapterTitle: String
    let onBegin: () -> Void
    let onScrub: (Double) -> Void
    let onEnd: () -> Void

    private static let trackHeight: CGFloat = 44
    private static let thumbWidth: CGFloat = 4

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            if isDragging { bubble }
            track
        }
        .animation(.default, value: isDragging)
    }

    private var bubble: some View {
        VStack(spacing: 2) {
            Text(chapterTitle)
                .font(TsuyomiTheme.Typography.sectionTitle)
                .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                .lineLimit(1)
            Text("第 \(pageIndex + 1) 页")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 12)
                    .fill(TsuyomiTheme.Palette.primaryText.opacity(0.12))
                    .frame(width: max(proxy.size.width * fraction, 0))
                Capsule()
                    .fill(TsuyomiTheme.Palette.primaryText)
                    .frame(width: Self.thumbWidth, height: Self.trackHeight - 20)
                    .offset(x: thumbOffset(in: proxy.size.width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onBegin()
                        }
                        onScrub(clamped(value.location.x / max(proxy.size.width, 1)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnd()
                    }
            )
        }
        .frame(height: Self.trackHeight)
        .accessibilityElement()
        .accessibilityLabel("阅读进度")
        .accessibilityValue("第 \(pageIndex + 1) 页，共 \(pageCount) 页")
        .accessibilityAdjustableAction { direction in
            let step = 1.0 / Double(max(pageCount - 1, 1))
            onBegin()
            onScrub(clamped(fraction + (direction == .increment ? step : -step)))
            onEnd()
        }
    }

    private var fraction: Double {
        guard pageCount > 1 else { return 0 }
        return clamped(Double(pageIndex) / Double(pageCount - 1))
    }

    /// The thumb stays inside the track at both ends rather than hanging half off it.
    private func thumbOffset(in width: CGFloat) -> CGFloat {
        let travel = max(width - Self.thumbWidth - 12, 0)
        return 6 + travel * fraction
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
