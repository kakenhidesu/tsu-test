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

/// Top and bottom reader chrome. The progress slider drives a preview session: dragging shows a
/// frozen preview, and only releasing performs the one semantic navigation.
public struct ReaderChrome: View {
    private let bookTitle: String
    private let chapterTitle: String
    private let pageIndex: Int
    private let pageCount: Int
    private let isVisible: Bool
    private let progressVisible: Bool
    private let actions: ReaderChromeActions
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    public init(
        bookTitle: String,
        chapterTitle: String,
        pageIndex: Int,
        pageCount: Int,
        isVisible: Bool,
        progressVisible: Bool,
        actions: ReaderChromeActions
    ) {
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.isVisible = isVisible
        self.progressVisible = progressVisible
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isVisible { topBar }
            Spacer(minLength: 0)
            if isVisible {
                bottomBar
            } else if progressVisible {
                inlineProgress
            }
        }
        .animation(.default, value: isVisible)
    }

    private var topBar: some View {
        HStack(spacing: TsuyomiTheme.Metrics.gutter) {
            Button(action: actions.onBack) {
                Label("返回", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .frame(minWidth: TsuyomiTheme.Metrics.minimumTouchTarget,
                   minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            VStack(alignment: .leading, spacing: 0) {
                Text(bookTitle)
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .lineLimit(1)
                Text(chapterTitle)
                    .font(TsuyomiTheme.Typography.sectionTitle)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
        .background(.bar)
    }

    private var bottomBar: some View {
        VStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            if pageCount > 1 {
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
            HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                Button {
                    actions.onPreviousChapter?()
                } label: {
                    Label("上一章", systemImage: "backward.end")
                }
                .disabled(actions.onPreviousChapter == nil)
                Spacer()
                Button(action: actions.onOpenDirectory) {
                    Label("目录", systemImage: "list.bullet")
                }
                Button(action: actions.onOpenSettings) {
                    Label("阅读设置", systemImage: "textformat.size")
                }
                Spacer()
                Button {
                    actions.onNextChapter?()
                } label: {
                    Label("下一章", systemImage: "forward.end")
                }
                .disabled(actions.onNextChapter == nil)
            }
            .labelStyle(.iconOnly)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
        .background(.bar)
    }

    private var inlineProgress: some View {
        Text("\(pageIndex + 1) / \(pageCount)")
            .font(TsuyomiTheme.Typography.caption)
            .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
            .padding(.bottom, 4)
            .accessibilityLabel("第 \(pageIndex + 1) 页，共 \(pageCount) 页")
    }
}
