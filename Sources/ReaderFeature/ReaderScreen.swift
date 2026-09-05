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

    public var body: some View {
        StateView(model.state, retry: { Task { await model.open() } }) { content in
            GeometryReader { proxy in
                ZStack {
                    ReaderSurface(
                        layout: content.layout,
                        pageIndex: model.visiblePageIndex,
                        flow: model.settings.flow,
                        theme: model.settings.theme,
                        horizontalMargin: model.settings.horizontalMargin,
                        onTap: { model.tapped($0) },
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
                .onAppear { model.resize(proxy.size) }
                .onChange(of: proxy.size) { size in model.resize(size) }
            }
        }
        .background(model.settings.theme.background)
        .navigationBarHidden(true)
        .statusBarHidden(model.settings.immersive && !model.isChromeVisible)
        .persistentSystemOverlays(model.settings.immersive ? .hidden : .automatic)
        .task { await model.open() }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            Task { await model.flush() }
        }
        // One sheet, not two: on iOS 16 a second `.sheet` on the same view silently never presents,
        // which would make the directory unreachable once the settings sheet had been attached.
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
                    .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
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
