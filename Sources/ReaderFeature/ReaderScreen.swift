// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiReader
import TsuyomiUI

public struct ReaderScreen: View {
    @ObservedObject private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    private let onLeave: () -> Void

    public init(model: ReaderModel, onLeave: @escaping () -> Void) {
        self.model = model
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
                        theme: model.settings.theme,
                        transition: model.settings.pageTransition,
                        horizontalMargin: model.settings.horizontalMargin,
                        onTap: { model.tapped($0) },
                        onTurn: { model.turned(toPage: $0) },
                        onPageDrawn: { model.pageDrawn($0) }
                    )
                    ReaderChrome(
                        bookTitle: model.bookTitle,
                        chapterTitle: content.chapterTitle,
                        pageIndex: model.visiblePageIndex,
                        pageCount: content.pageCount,
                        isVisible: model.isChromeVisible,
                        progressVisible: model.settings.progressVisible,
                        actions: actions(content)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { model.resize(proxy.size) }
            .onChange(of: proxy.size) { size in model.resize(size) }
        }
        .background(model.settings.theme.background)
        /// A reader theme is the reader's own choice, not the system's. Everything drawn over it
        /// resolves semantic colours, so the subtree is told which appearance it is sitting on;
        /// otherwise a dark system appearance writes near-white text onto a paper background.
        .environment(\.colorScheme, model.settings.theme.colorScheme)
        .navigationBarHidden(true)
        /// Reading is the whole screen. A tab bar under the text is one more thing to hit by accident
        /// while turning a page, and it says the reader is a pane inside a tab when it is not.
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(model.settings.immersive && !model.isChromeVisible)
        .persistentSystemOverlays(model.settings.immersive ? .hidden : .automatic)
        .task { await model.open() }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            Task { await model.flush() }
        }
        .sheet(
            isPresented: Binding(
                get: { model.isSettingsPresented || model.isDirectoryPresented },
                set: { presented in
                    guard !presented else { return }
                    model.isSettingsPresented = false
                    model.isDirectoryPresented = false
                }
            )
        ) {
            if model.isSettingsPresented {
                ReaderSettingsSheet(settings: $model.settings) { model.apply($0) }
            } else {
                directory
            }
        }
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
            onScrubEnd: { model.endScrub() }
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
