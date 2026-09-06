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
    public let onScrubEnd: (Double) -> Void

    public init(
        onBack: @escaping () -> Void,
        onPreviousChapter: (() -> Void)?,
        onNextChapter: (() -> Void)?,
        onOpenDirectory: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onScrubBegin: @escaping () -> Void,
        onScrub: @escaping (Double) -> Void,
        onScrubEnd: @escaping (Double) -> Void
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
    @State private var isScrubbing = false
    @State private var scrubFraction: Double?

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

    /// Rows, not a system menu: the 目录 row is also the scrubber, which a menu cannot hold, and a
    /// menu dismisses itself on the way to a sheet, which reads as the panel flickering away.
    private var panel: some View {
        VStack(alignment: .trailing, spacing: TsuyomiTheme.Metrics.tightGutter) {
            if isScrubbing { bubble }
            /// Two cards, not one card with a rule through it: the reference separates them, and they
            /// are separate things — one is where you are in the chapter, the other is what the page
            /// looks like.
            directoryRow
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            panelRow(title: "主题与设置", symbol: "textformat.size") {
                isMenuOpen = false
                actions.onOpenSettings()
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
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

    /// The 目录 row is the scrubber. It stays a row — the name, the percentage and the icon keep their
    /// places — and while a finger drags along it the read portion fills in underneath them, so the
    /// row is the track rather than being swapped for one. Dragging drives the preview session — a
    /// frozen preview follows the finger — and releasing performs the one navigation. A tap that does
    /// not travel opens the directory instead.
    private var directoryRow: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                /// The proportion is on the row at rest, not only under a finger: this is where the
                /// reader looks to see how far in they are, and a bar that only appears once you drag
                /// it cannot answer that. One length for both marks — the fill ends at `edge` and the
                /// marker stands on `edge` — so there is no second formula to disagree by, and the
                /// finger maps back through the same width below.
                let edge = proxy.size.width * fraction
                Rectangle()
                    .fill(TsuyomiTheme.Palette.primaryText.opacity(0.14))
                    .frame(width: edge)
                Rectangle()
                    .fill(TsuyomiTheme.Palette.primaryText.opacity(isScrubbing ? 1 : 0.5))
                    .frame(width: 2, height: 24)
                    .offset(x: edge - 1)
                HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                    Text("目录")
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    Text("\(percentRead)%")
                        .font(TsuyomiTheme.Typography.supporting)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    Spacer()
                    Image(systemName: "list.bullet")
                        .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                isMenuOpen = false
                actions.onOpenDirectory()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            actions.onScrubBegin()
                        }
                        scrubFraction = clamped(value.location.x / max(proxy.size.width, 1))
                        actions.onScrub(scrubFraction ?? 0)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        actions.onScrubEnd(scrubFraction ?? 0)
                        scrubFraction = nil
                    }
            )
        }
        .frame(height: 52)
        .accessibilityElement()
        .accessibilityLabel("目录与阅读进度")
        .accessibilityValue("第 \(pageIndex + 1) 页，共 \(pageCount) 页")
        .accessibilityAdjustableAction { direction in
            let step = 1.0 / Double(max(pageCount - 1, 1))
            let target = clamped(fraction + (direction == .increment ? step : -step))
            actions.onScrubBegin()
            actions.onScrub(target)
            actions.onScrubEnd(target)
        }
    }

    /// A bar moving under a covered thumb says nothing about where it has got to, so while the finger
    /// is down the chapter and the page it would land on are named above the panel.
    private var bubble: some View {
        VStack(spacing: 2) {
            Text(chapterTitle)
                .font(TsuyomiTheme.Typography.sectionTitle)
                .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                .lineLimit(1)
            Text("第 \(scrubTargetPage + 1) 页")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Where the bar is, which while a finger is down is where the finger is. Reading it back from
    /// the page instead would leave the bar wherever the preview managed to reach, which is not what
    /// the reader is pointing at.
    private var fraction: Double {
        if let scrubFraction { return scrubFraction }
        guard pageCount > 1 else { return 0 }
        return clamped(Double(pageIndex) / Double(pageCount - 1))
    }

    private var scrubTargetPage: Int {
        min(max(Int((fraction * Double(max(pageCount - 1, 0))).rounded()), 0), max(pageCount - 1, 0))
    }

    private func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func panelRow(title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Text(title)
                    .font(TsuyomiTheme.Typography.body)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
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

    /// Read from the page the bar points at, so the figure moves with the finger.
    private var percentRead: Int {
        guard pageCount > 0 else { return 0 }
        return Int((Double(scrubTargetPage + 1) / Double(pageCount) * 100).rounded())
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
