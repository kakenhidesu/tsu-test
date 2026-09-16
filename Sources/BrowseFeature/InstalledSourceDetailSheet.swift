// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// What an installed source is and may do, as the verified package declares it. Nothing here can
/// be changed: this is the record, and the review screen was where it was granted.
struct InstalledSourceDetailSheet: View {
    let row: BrowseSourceRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(row.source.summary)
                        .font(TsuyomiTheme.Typography.body)
                    LabeledContent("标识", value: row.source.sourceId.value)
                    LabeledContent("版本", value: row.source.version.original)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发布者指纹")
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        Text(row.source.publisherFingerprint)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                Section("网络") {
                    ForEach(
                        row.source.networkOrigins.map(\.canonical).sorted(),
                        id: \.self
                    ) { origin in
                        Text(origin)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                Section("能力") {
                    capability("来源首页", granted: row.source.supportsHome)
                    capability("网页登录", granted: row.source.supportsWebLogin)
                    capability("读取网站书架", granted: row.source.supportsRemoteRead)
                    capability("写入网站书架", granted: row.source.supportsRemoteAdd)
                }
            }
            .navigationTitle(row.source.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func capability(_ title: LocalizedStringKey, granted: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? TsuyomiTheme.Palette.success : TsuyomiTheme.Palette.tertiaryText)
                .accessibilityLabel(granted ? "已声明" : "未声明")
        }
    }
}
