// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// Trust management. Removing a publisher is the strongest action in the market: every package it
/// signed stops verifying, so the sources become dormant until the publisher is trusted again.
public struct PublisherKeysScreen: View {
    @ObservedObject private var model: ExtensionsModel
    @State private var pendingRemoval: TrustedPublisher?

    public init(model: ExtensionsModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if model.trustedPublishers.isEmpty {
                Text("还没有信任任何发布者。添加一个仓库后，它的发布者会出现在这里。")
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            } else {
                ForEach(model.trustedPublishers, id: \.keyId) { publisher in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(publisher.keyId)
                            .font(TsuyomiTheme.Typography.body)
                        Text(publisher.fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                            TsuyomiStatusBadge(
                                publisher.trust == .userAdded ? "用户添加" : "内置测试",
                                tone: publisher.trust == .userAdded ? .neutral : .warning
                            )
                            if let repositoryId = publisher.repositoryId {
                                Text(repositoryId)
                                    .font(TsuyomiTheme.Typography.caption)
                                    .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                            }
                        }
                    }
                    .swipeActions {
                        Button("移除信任", role: .destructive) { pendingRemoval = publisher }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发布者")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "移除这个发布者？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("移除信任", role: .destructive) {
                guard let keyId = pendingRemoval?.keyId else { return }
                pendingRemoval = nil
                Task { await model.forgetPublisher(keyId) }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("它签名的所有已安装扩展会立即停用，对应来源变为休眠。书架内容与登录凭据都会保留。")
        }
    }
}
