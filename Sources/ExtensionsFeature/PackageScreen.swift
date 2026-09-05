// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// What a package would be allowed to do, read from the index before anything is downloaded. This is
/// a preview only: the grant is decided by the manifest inside the archive, and a disagreement
/// between the two stops the install.
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
                }
                Section("网络") {
                    if package.capabilities.network.origins.isEmpty {
                        Text("不访问网络")
                    } else {
                        ForEach(package.capabilities.network.origins.map(\.canonical).sorted(), id: \.self) { origin in
                            Text(origin).font(.system(.footnote, design: .monospaced))
                        }
                    }
                    LabeledContent("并发请求", value: "\(package.capabilities.network.maximumConcurrentRequests)")
                    LabeledContent("单次响应上限", value: PackageScreen.size(package.capabilities.network.maximumResponseBytes))
                }
                Section("Cookie") {
                    if package.capabilities.cookies.sourceScoped {
                        ForEach(package.capabilities.cookies.origins.map(\.canonical).sorted(), id: \.self) { origin in
                            Text(origin).font(.system(.footnote, design: .monospaced))
                        }
                    } else {
                        Text("不使用 Cookie")
                    }
                }
                Section("网站登录") {
                    if package.capabilities.webLogin.enabled {
                        ForEach(package.capabilities.webLogin.origins.map(\.canonical).sorted(), id: \.self) { origin in
                            Text(origin).font(.system(.footnote, design: .monospaced))
                        }
                    } else {
                        Text("不需要登录")
                    }
                }
                Section("网站收藏") {
                    Text(package.capabilities.remoteLibrary.read ? "可读取网站收藏" : "不读取网站收藏")
                    if package.capabilities.remoteLibrary.writeOperations.isEmpty {
                        Text("不写入网站收藏")
                    } else {
                        Text("可写入：\(package.capabilities.remoteLibrary.writeOperations.sorted().joined(separator: "、"))")
                    }
                }
                Section("其他") {
                    Text(package.capabilities.home.enabled ? "提供首页" : "不提供首页")
                    LabeledContent("存储配额", value: PackageScreen.size(package.capabilities.storageQuotaBytes))
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
