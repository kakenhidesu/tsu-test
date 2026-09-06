// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiReader
import TsuyomiUI

public struct ReaderScreen: View {
    @ObservedObject private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    /// The app's appearance, which the reader's own panel offers beside the page themes exactly as
    /// the reference does: a theme is two palettes, and this decides which one the page is drawn in.
    @Binding private var appearance: ColorSchemePreference
    @Environment(\.colorScheme) private var colorScheme
    private let onLeave: () -> Void

    /// The page's colours. The palette is chosen by the appearance the subtree already has, so the
    /// semantic colours drawn over the page resolve against the page without being told to.
    private var palette: ReaderPalette { model.settings.theme.palette(for: colorScheme) }

    public init(
        model: ReaderModel,
        appearance: Binding<ColorSchemePreference>,
        onLeave: @escaping () -> Void
    ) {
        self.model = model
        self._appearance = appearance
        self.onLeave = onLeave
    }

    /// The viewport is measured outside the state branch. Pagination is what produces the content
    /// state, and it cannot run until the page size is known, so measuring only once content exists
    /// leaves the reader loading forever.
    public var body: some View {
        GeometryReader { proxy in
            StateView(model.state, retry: { Task { await model.open() } }) { content in
                ZStack {
                    ReaderSurface(
                        layout: content.layout,
                        pageIndex: model.visiblePageIndex,
                        flow: model.settings.flow,
                        palette: palette,
                        transition: model.settings.pageTransition,
                        horizontalMargin: model.settings.horizontalMargin,
                        onTap: { model.tapped($0) },
                        onTurn: { model.turned(toPage: $0) },
                        onPageDrawn: { model.pageDrawn($0) }
                    )
                    /// The page stops where the chrome starts. Text drawn under the running head is
                    /// unreadable whether or not the controls are up, because the head is always up.
                    .padding(.top, ReaderChromeMetrics.headerHeight)
                    .padding(.bottom, ReaderChromeMetrics.footerHeight)
                    ReaderChrome(
                        chapterTitle: content.chapterTitle,
                        pageIndex: model.visiblePageIndex,
                        pageCount: content.pageCount,
                        isVisible: model.isChromeVisible,
                        progressVisible: model.settings.progressVisible,
                        actions: actions(content)
                    )
                    if model.isSettingsPresented { settingsPanel }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.default, value: model.isSettingsPresented)
            }
            .onAppear { model.resize(readingSize(proxy.size)) }
            .onChange(of: proxy.size) { size in model.resize(readingSize(size)) }
        }
        .background(palette.background)
        .navigationBarHidden(true)
        /// Reading is the whole screen. A tab bar under the text is one more thing to hit by accident
        /// while turning a page, and it says the reader is a pane inside a tab when it is not.
        .toolbar(.hidden, for: .tabBar)
        /// The clock and the home indicator belong to the controls, not to the page: with the chrome
        /// away there is nothing on screen but the text, and one tap brings all of it back together.
        .statusBarHidden(!model.isChromeVisible)
        .persistentSystemOverlays(model.isChromeVisible ? .automatic : .hidden)
        .task { await model.open() }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            Task { await model.flush() }
        }
        .sheet(isPresented: $model.isDirectoryPresented) { directory }
    }

    /// Drawn over the page rather than presented over it: a sheet can be pulled past its one height
    /// and springs back, and there is no switch for that. Here the panel is as tall as its controls
    /// and no taller, and a tap on the page or a pull downwards puts it away.
    @ViewBuilder
    private var settingsPanel: some View {
        Color.black.opacity(0.001)
            .onTapGesture { model.isSettingsPresented = false }
            .accessibilityHidden(true)
        ReaderSettingsSheet(
            settings: $model.settings,
            appearance: $appearance,
            onChange: { model.apply($0) },
            onClose: { model.isSettingsPresented = false }
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom))
        .zIndex(1)
    }

    /// Pagination is measured against the box the text actually gets, which is the screen less the
    /// chrome. Measuring the whole screen would plan more lines onto a page than fit on it.
    private func readingSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: max(size.height - ReaderChromeMetrics.headerHeight - ReaderChromeMetrics.footerHeight, 1)
        )
    }

    private func actions(_ content: ReaderContent) -> ReaderChromeActions {
        ReaderChromeActions(
            onBack: {
                Task {
                    await model.flush()
                    onLeave()
                }
            },
            onPreviousChapter: content.hasPrevious ? { Task { await model.openAdjacent(-1) } } : nil,
            onNextChapter: content.hasNext ? { Task { await model.openAdjacent(1) } } : nil,
            onOpenDirectory: { model.isDirectoryPresented = true },
            onOpenSettings: { model.isSettingsPresented = true },
            onScrubBegin: { model.beginScrub() },
            onScrub: { model.scrub($0) },
            onScrubEnd: { model.endScrub(at: $0) }
        )
    }

    private var directory: some View {
        NavigationStack {
            List(model.chapters, id: \.chapterId) { entry in
                Button {
                    Task { await model.open(chapterId: entry.chapterId) }
                } label: {
                    HStack {
                        Text(entry.title)
                            .font(TsuyomiTheme.Typography.body)
                            .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                        Spacer()
                        if entry.chapterId == model.chapter?.chapterId {
                            TsuyomiStatusBadge("当前", tone: .positive)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { model.isDirectoryPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
    }
}
