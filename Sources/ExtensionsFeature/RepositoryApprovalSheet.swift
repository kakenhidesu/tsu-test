// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// Approving a repository is approving the root key the reader typed and every publisher that key
/// vouches for. The fingerprints and the risk of running third party code in this process are both
/// stated here, because this is the last screen before trust.
struct RepositoryApprovalSheet: View {
    let pending: PendingRepositoryApproval
    @ObservedObject var model: ExtensionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("仓库") {
                    LabeledContent("标识", value: pending.index.repositoryId)
                    Text(pending.descriptor.indexUrl.absoluteString)
                        .font(.system(.footnote, design: .monospaced))
                    LabeledContent("目录序号", value: "\(pending.index.sequence)")
                    LabeledContent("包数量", value: "\(pending.index.packages.count)")
                    LabeledContent("有效期至", value: ProtocolTimestampText.short(pending.index.expiresAt))
                }
                Section("根密钥") {
                    LabeledContent("Key ID", value: pending.descriptor.rootKeyId)
                    fingerprintRow(pending.descriptor.rootKey.fingerprint)
                }
                Section("发布者") {
                    ForEach(pending.index.publishers, id: \.keyId) { publisher in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(publisher.keyId)
                                .font(TsuyomiTheme.Typography.body)
                            fingerprintRow(publisher.fingerprint)
                            if pending.newPublisherKeyIds.contains(publisher.keyId) {
                                TsuyomiStatusBadge("新的发布者密钥", tone: .warning)
                            }
                        }
                    }
                }
                Section {
                    Text("扩展在应用进程内运行，QuickJS 不是进程级沙箱；信任这些发布者等同于信任它们的代码。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
                }
            }
            .navigationTitle("确认仓库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        model.discardApproval()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("信任并添加") {
                        Task {
                            await model.approvePendingRepository()
                            dismiss()
                        }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private func fingerprintRow(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("公钥指纹")
                .font(TsuyomiTheme.Typography.caption)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}
