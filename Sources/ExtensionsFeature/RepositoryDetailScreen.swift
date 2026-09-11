// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiSource
import TsuyomiUI

public struct RepositoryDetailScreen: View {
    @ObservedObject private var model: RepositoryDetailModel
    private let onRemoved: () -> Void
    @State private var selected: RepositoryPackage?
    @State private var isConfirmingRemoval = false

    public init(model: RepositoryDetailModel, onRemoved: @escaping () -> Void) {
        self.model = model
        self.onRemoved = onRemoved
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.refresh() } }) { content in
            List {
                if let code = model.failureCode {
                    Text("上一步没有完成（\(code)）。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
                }
                Section {
                    LabeledContent("目录序号", value: "\(content.index.sequence)")
                    LabeledContent("根密钥", value: content.index.rootKeyId)
                    LabeledContent("目录有效期至", value: ProtocolTimestampText.short(content.index.expiresAt))
                }
                if !content.untrustedPublishers.isEmpty {
                    Section("尚未信任的发布者") {
                        ForEach(content.untrustedPublishers, id: \.keyId) { publisher in
                            publisherRow(publisher)
                        }
                    }
                }
                Section("扩展包") {
                    ForEach(content.rows) { row in
                        Button { selected = row.package } label: { packageRow(row) }
                            .buttonStyle(.plain)
                            .disabled(row.status == .revoked)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(model.descriptor.repositoryId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("移除仓库", role: .destructive) { isConfirmingRemoval = true }
                    .disabled(model.isBusy)
            }
        }
        .confirmationDialog("移除这个仓库？", isPresented: $isConfirmingRemoval) {
            Button("移除", role: .destructive) { onRemoved() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除它的缓存目录。已安装的扩展继续可用，发布者信任也保留，可在发布者页单独管理。")
        }
        .sheet(
            isPresented: Binding(
                get: { selected != nil || model.pendingInstall != nil },
                set: { presented in
                    guard !presented else { return }
                    selected = nil
                    model.discardPendingInstall()
                }
            )
        ) {
            if let prepared = model.pendingInstall {
                InstallReviewScreen(
                    prepared: prepared,
                    isBusy: model.isBusy,
                    onApprove: { Task { await model.approvePendingInstall() } },
                    onCancel: { model.discardPendingInstall() }
                )
            } else if let package = selected {
                PackageScreen(package: package, model: model)
            }
        }
        .task { await model.loadCached() }
    }

    /// A listed publisher the reader has not trusted yet. Its packages stay listed but cannot be
    /// installed until this row is accepted, which is the same act as approving the repository.
    private func publisherRow(_ publisher: RepositoryPublisher) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(publisher.keyId)
                .font(TsuyomiTheme.Typography.body)
            Text(publisher.fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            Button("信任这个发布者") { Task { await model.trustPublisher(publisher) } }
                .disabled(model.isBusy)
        }
    }

    private func packageRow(_ row: RepositoryPackageRow) -> some View {
        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.package.displayName)
                    .font(TsuyomiTheme.Typography.body)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                Text("\(row.package.id.value) · \(row.package.version.original)")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            }
            Spacer()
            badge(row.status)
        }
    }

    @ViewBuilder
    private func badge(_ status: PackageStatus) -> some View {
        switch status {
        case .available: EmptyView()
        case .installed: TsuyomiStatusBadge("已安装", tone: .neutral)
        case .updatable(let from): TsuyomiStatusBadge("可从 \(from) 更新", tone: .positive)
        case .incompatible: TsuyomiStatusBadge("宿主版本不兼容", tone: .warning)
        case .revoked: TsuyomiStatusBadge("已撤销", tone: .danger)
        }
    }
}

/// The package's own source id already identifies it for presentation: only one version of a package
/// can be on screen at a time.
extension RepositoryPackage: Identifiable {}

enum ProtocolTimestampText {
    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
