// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// What the catalog says about a package before anything is downloaded. The catalog carries no
/// capability preview: the grant is decided by the manifest inside the archive, which the review
/// screen shows in full once the bytes have been verified.
public struct PackageScreen: View {
    let package: RepositoryPackage
    @ObservedObject var model: RepositoryDetailModel
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(package.summary)
                        .font(TsuyomiTheme.Typography.body)
                    LabeledContent("标识", value: package.id.value)
                    LabeledContent("版本", value: package.version.original)
                    LabeledContent(
                        "宿主 API",
                        value: "\(package.hostApiMinInclusive.original) ≤ x < \(package.hostApiMaxExclusive.original)"
                    )
                    LabeledContent("大小", value: PackageScreen.size(package.sizeBytes))
                    LabeledContent("语言", value: package.language)
                    LabeledContent("许可证", value: package.license)
                }
                Section("来源") {
                    LabeledContent("发布者", value: package.publisherKeyId)
                    Text(package.sourceUrl.absoluteString)
                        .font(.system(.footnote, design: .monospaced))
                    LabeledContent("源码修订", value: String(package.sourceRevision.prefix(12)))
                }
                Section {
                    Text("能力清单在下载并校验后的安装审批页里逐项显示；同意安装前不会授予任何能力。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
                Section {
                    Button(action) {
                        Task {
                            await model.prepare(package)
                            dismiss()
                        }
                    }
                    .disabled(model.isBusy)
                }
            }
            .navigationTitle(package.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var action: LocalizedStringKey {
        if case .content(let content) = model.state,
           case .updatable = content.rows.first(where: { $0.package.id == package.id })?.status {
            return "下载并检查更新"
        }
        return "下载并检查"
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
