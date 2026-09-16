// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI
import TsuyomiUpdates

/// The latest session, item by item. Reasons are shown as labels; a raw token appears only when
/// it is the host's own bounded diagnostic.
@MainActor
public final class UpdateReportModel: ObservableObject {
    public static let pageSize = 100

    @Published public private(set) var session: UpdateSessionSummary?
    @Published public private(set) var items: [UpdateSessionItemSummary] = []
    @Published public private(set) var hasMore = false

    private let updates: UpdateStore

    public init(updates: UpdateStore) {
        self.updates = updates
    }

    public func load() async {
        session = try? await updates.latestSession()
        items = []
        hasMore = false
        await loadMore()
    }

    public func loadMore() async {
        guard let session else { return }
        let page = (try? await updates.sessionItems(session.sessionId, limit: UpdateReportModel.pageSize, offset: items.count)) ?? []
        items += page
        hasMore = page.count == UpdateReportModel.pageSize && items.count < session.total
    }
}

public struct UpdateReportScreen: View {
    @StateObject private var model: UpdateReportModel
    @Environment(\.dismiss) private var dismiss

    public init(model: @autoclosure @escaping () -> UpdateReportModel) {
        _model = StateObject(wrappedValue: model())
    }

    public var body: some View {
        NavigationStack {
            List {
                if let session = model.session {
                    Section {
                        Text(UpdateReport.summary(session))
                            .font(TsuyomiTheme.Typography.supporting)
                        if let reason = session.reason {
                            Text(reason)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        }
                    }
                    Section {
                        ForEach(model.items, id: \.identity) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.capturedTitle)
                                        .font(TsuyomiTheme.Typography.body)
                                    if let reason = UpdateReport.reason(item.reason) {
                                        Text(reason)
                                            .font(TsuyomiTheme.Typography.caption)
                                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                                    }
                                }
                                Spacer()
                                TsuyomiStatusBadge(LocalizedStringKey(UpdateReport.label(item.state)), tone: tone(item.state))
                            }
                        }
                        if model.hasMore {
                            Button("更多报告 (\(model.items.count)/\(session.total))") { Task { await model.loadMore() } }
                        }
                    }
                } else {
                    Text("还没有检查过更新。")
                        .font(TsuyomiTheme.Typography.supporting)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("更新报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await model.load() }
        }
    }

    private func tone(_ state: UpdateItemState) -> TsuyomiStatusTone {
        switch state {
        case .updated: return .positive
        case .failed, .unavailable: return .danger
        case .skipped, .cancelled: return .warning
        case .pending, .unchanged: return .neutral
        }
    }
}
