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

/// Almost nothing, which is the point. Reading, the page carries only the chapter it belongs to and
/// the page number. A tap in the middle brings back the two controls there are — close, and a menu —
/// and the page number gains its total. The progress slider drives a preview session: dragging shows
/// a frozen preview, and only releasing performs the one semantic navigation.
public struct ReaderChrome: View {
    private let chapterTitle: String
    private let pageIndex: Int
    private let pageCount: Int
    private let isVisible: Bool
    private let progressVisible: Bool
    private let actions: ReaderChromeActions
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

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
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
        .animation(.default, value: isVisible)
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
                    CircularChromeButton(symbol: "xmark", label: "关闭", action: actions.onBack)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            if isVisible, pageCount > 1 { scrubber }
            ZStack {
                if isVisible || progressVisible { pageIndicator }
                if isVisible {
                    HStack {
                        Spacer()
                        menu
                    }
                }
            }
        }
    }

    private var pageIndicator: some View {
        Text(isVisible ? "\(pageIndex + 1)/\(pageCount) 页" : "\(pageIndex + 1)")
            .font(TsuyomiTheme.Typography.caption)
            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            .padding(.horizontal, TsuyomiTheme.Metrics.minimumTouchTarget)
            .accessibilityLabel("第 \(pageIndex + 1) 页，共 \(pageCount) 页")
    }

    private var menu: some View {
        Menu {
            Button {
                actions.onOpenDirectory()
            } label: {
                Label("目录", systemImage: "list.bullet")
            }
            Button {
                actions.onOpenSettings()
            } label: {
                Label("主题与设置", systemImage: "textformat.size")
            }
            if let previous = actions.onPreviousChapter {
                Button { previous() } label: { Label("上一章", systemImage: "backward.end") }
            }
            if let next = actions.onNextChapter {
                Button { next() } label: { Label("下一章", systemImage: "forward.end") }
            }
        } label: {
            CircularChromeLabel(symbol: "ellipsis")
        }
        .accessibilityLabel("更多")
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { isScrubbing ? scrubValue : Double(pageIndex) },
                set: { value in
                    scrubValue = value
                    actions.onScrub(value)
                }
            ),
            in: 0...Double(max(pageCount - 1, 1)),
            step: 1,
            onEditingChanged: { editing in
                isScrubbing = editing
                if editing {
                    scrubValue = Double(pageIndex)
                    actions.onScrubBegin()
                } else {
                    actions.onScrubEnd()
                }
            }
        )
        .accessibilityLabel("阅读进度")
        .accessibilityValue("第 \(Int(isScrubbing ? scrubValue : Double(pageIndex)) + 1) 页，共 \(pageCount) 页")
    }
}

/// A control that floats over the page rather than sitting in a bar: the page keeps its full height
/// whether the controls are up or not, so bringing them back never reflows a word of text.
struct CircularChromeLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            .frame(
                width: TsuyomiTheme.Metrics.minimumTouchTarget,
                height: TsuyomiTheme.Metrics.minimumTouchTarget
            )
            .background(.thinMaterial, in: Circle())
    }
}

struct CircularChromeButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircularChromeLabel(symbol: symbol)
        }
        .accessibilityLabel(label)
    }
}
