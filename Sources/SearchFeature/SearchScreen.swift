// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct SearchScreen: View {
    @ObservedObject private var model: SearchModel
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openBook: (BookIdentity) -> Void

    public init(
        model: SearchModel,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void
    ) {
        self.model = model
        self.coverState = coverState
        self.openBook = openBook
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: TsuyomiTheme.Metrics.gutter)]

    public var body: some View {
        VStack(spacing: 0) {
            field
            if !model.history.isEmpty {
                historyStrip
            }
            StateView(model.state, retry: { Task { await model.submit() } }) { results in
                results.isStaleOffline ? staleResults(results) : freshResults(results)
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadHistory() }
    }

    /// Submission happens inside the field: there is no separate search button to disagree with it.
    private var field: some View {
        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            TextField("书名或作者", text: $model.query)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await model.submit() } }
            if model.isBusy {
                ProgressView()
            }
        }
        .padding(TsuyomiTheme.Metrics.tightGutter)
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        .background(TsuyomiTheme.Palette.raisedSurface, in: RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius))
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
    }

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                ForEach(model.history, id: \.self) { entry in
                    Button(entry) { Task { await model.useHistory(entry) } }
                        .buttonStyle(.bordered)
                }
                Button("清除历史") { Task { await model.clearHistory() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(TsuyomiTheme.Palette.danger)
            }
            .font(TsuyomiTheme.Typography.supporting)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
    }

    @ViewBuilder
    private func staleResults(_ results: SearchResults) -> some View {
        VStack(spacing: 0) {
            TsuyomiStatusBadge("离线缓存结果", tone: .warning)
                .padding(.bottom, TsuyomiTheme.Metrics.tightGutter)
            freshResults(results)
        }
    }

    private func freshResults(_ results: SearchResults) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
                    ForEach(results.items, id: \.identity) { item in
                        TsuyomiCoverGridCard(
                            title: item.title,
                            cover: coverState(item),
                            action: { openBook(item.identity) }
                        )
                    }
                }
                .padding(TsuyomiTheme.Metrics.gutter)
            }
            PaginationBar(
                page: results.page,
                hasPrevious: results.page > 1,
                hasNext: !results.items.isEmpty,
                onPrevious: { Task { await model.loadPage(results.page - 1) } },
                onNext: { Task { await model.loadPage(results.page + 1) } }
            )
        }
    }
}
