// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct SourceHomeScreen: View {
    @ObservedObject private var model: SourceHomeModel
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openBook: (BookIdentity) -> Void
    @State private var selectedFeature: String?

    public init(
        model: SourceHomeModel,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void
    ) {
        self.model = model
        self.coverState = coverState
        self.openBook = openBook
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
                    if !content.page.features.isEmpty {
                        featureTabs(content.page.features)
                    }
                    if !content.page.filters.isEmpty {
                        TsuyomiFilterCapsules(
                            filters: content.page.filters,
                            selection: content.pendingFilters,
                            onSelect: { model.select(filterId: $0, optionValue: $1) }
                        )
                        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
                        if model.hasPendingChanges {
                            Button("应用筛选") {
                                Task { await model.load() }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
                        }
                    }
                    ForEach(content.page.sections, id: \.id) { section in
                        sectionView(section)
                    }
                    if let cursor = model.nextCursor {
                        Button("载入下一页") {
                            Task { await model.load(cursor: cursor) }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
                    }
                }
                .padding(.vertical, TsuyomiTheme.Metrics.gutter)
            }
        }
        .overlay(alignment: .bottom) {
            if model.isBusy {
                ProgressView().padding()
            }
        }
        .navigationTitle(title)
        /// Opening a source's home page is the request; it does not need a second one. Filters are
        /// still applied explicitly, and 重新载入 is for when a load failed or the reader wants a
        /// fresh one.
        .task { await model.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新载入") {
                    Task { await model.load() }
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var title: String {
        if case .content(let content) = model.state { return content.page.title }
        return "来源首页"
    }

    /// Featured destinations are equal-width so their labels cannot reflow the row as they change.
    private func featureTabs(_ features: [SourceHomeFeature]) -> some View {
        TsuyomiTabs(
            tabs: features.map { (value: $0.id, title: LocalizedStringKey($0.title)) },
            selection: Binding(
                get: { selectedFeature ?? features.first?.id ?? "" },
                set: { value in
                    selectedFeature = value
                    guard let feature = features.first(where: { $0.id == value }) else { return }
                    Task { await model.applyFeature(feature) }
                }
            )
        )
    }

    private func sectionView(_ section: SourceHomeSection) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
            Text(section.title)
                .font(TsuyomiTheme.Typography.sectionTitle)
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: TsuyomiTheme.Metrics.gutter) {
                    ForEach(section.items, id: \.identity) { item in
                        TsuyomiCoverGridCard(
                            title: item.title,
                            cover: coverState(item),
                            action: { openBook(item.identity) }
                        )
                        .frame(width: 108)
                    }
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            }
        }
    }
}
