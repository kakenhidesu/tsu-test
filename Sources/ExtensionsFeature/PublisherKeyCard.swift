// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// A local archive from a publisher nobody here trusts. The key id is what the archive claims; the
/// key the reader types is what decides whether the claim holds. Nothing is stored on this screen.
public struct PublisherKeyCard: View {
    let pending: PendingPublisherKey
    @ObservedObject var model: ExtensionsModel
    @State private var publicKey = ""

    public init(pending: PendingPublisherKey, model: ExtensionsModel) {
        self.pending = pending
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Text("这个内容源包由一位尚未信任的发布者签名。输入维护者公布的发布者公钥，用它来验证这份包；验证通过后再决定是否安装。")
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                LabeledContent("密钥 ID", value: pending.keyId)
            } header: {
                Text("需要发布者公钥")
            }
            Section {
                TextField("原始 Ed25519 公钥（Base64）", text: $publicKey, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...4)
            } footer: {
                if let code = model.failureCode {
                    Text("包未通过完整性、签名或兼容性验证（\(code)）。")
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
                } else {
                    Text("公钥只用于验证这一份包，不会被保存；安装审批通过后才会记为信任。")
                }
            }
            Section {
                Button("验证发布者公钥") { Task { await model.providePublisherKey(publicKey) } }
                    .disabled(publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Button("取消", role: .cancel) { model.discardPublisherKeyRequest() }
            }
        }
    }
}
