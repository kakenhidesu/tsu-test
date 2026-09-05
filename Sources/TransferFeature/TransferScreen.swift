// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI
import UniformTypeIdentifiers

/// Data transfer. Import shows the plan first and only writes when the reader says so; the report
/// afterwards is the record of what actually happened.
public struct TransferScreen: View {
    @ObservedObject private var model: TransferModel
    @State private var isImporting = false
    @State private var isExpandingWarnings = false

    private static let warningFoldThreshold = 50

    public init(model: TransferModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            if let code = model.failureCode {
                Section {
                    Text("上一步没有完成（\(code)）。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
                }
            }
            switch model.stage {
            case .idle:
                exportSection
                importSection
            case .previewing, .applying:
                previewSection
            case .reported:
                reportSection
            }
        }
        .navigationTitle("数据迁移")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await load(url) }
        }
    }

    private var exportSection: some View {
        Section("导出") {
            Text("导出的文件只包含书架、收藏夹、进度与阅读偏好，不含任何 Cookie 或登录信息。")
                .font(TsuyomiTheme.Typography.caption)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            Button("导出 tsuyomi-transfer") { Task { await model.export() } }
                .disabled(model.isBusy)
            if let file = model.exportedFile {
                ShareLink(item: file) { Text("分享导出的文件") }
            }
        }
    }

    private var importSection: some View {
        Section("导入") {
            Text("支持 tsuyomi-transfer 与 hikari_novel_backup。格式按文件内容判断，不看文件名。")
                .font(TsuyomiTheme.Typography.caption)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            Button("选择备份文件") { isImporting = true }
                .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let plan = model.plan {
            Section("将要导入") {
                LabeledContent("来源格式", value: plan.kind == .hikariBackup ? "hikari_novel_backup" : "tsuyomi-transfer")
                LabeledContent("书籍", value: "\(plan.books.count)")
                LabeledContent("收藏夹", value: "\(plan.shelves.count)")
                LabeledContent("智能收藏夹", value: "\(plan.smartCollections.count)")
                LabeledContent("警告", value: "\(plan.warnings.count)")
            }
            warningList(plan.warnings)
            Section {
                Button("执行导入") { Task { await model.apply() } }
                    .disabled(model.stage == .applying)
                Button("放弃", role: .destructive) { model.discardPreview() }
                    .disabled(model.stage == .applying)
            }
        }
    }

    @ViewBuilder
    private var reportSection: some View {
        if let report = model.report {
            Section("导入报告") {
                LabeledContent("已导入书籍", value: "\(report.summary.importedBooks)")
                LabeledContent("已导入收藏夹", value: "\(report.summary.importedShelves)")
                LabeledContent("警告", value: "\(report.summary.warningCount)")
            }
            warningList(report.warnings)
            Section {
                Button("完成") { model.discardPreview() }
            }
        }
    }

    /// Long warning lists are folded: a report that scrolls for a thousand rows is not a report.
    @ViewBuilder
    private func warningList(_ warnings: [ImportWarning]) -> some View {
        if !warnings.isEmpty {
            Section("警告") {
                let shown = isExpandingWarnings
                    ? warnings
                    : Array(warnings.prefix(TransferScreen.warningFoldThreshold))
                ForEach(shown, id: \.ordinal) { warning in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.safeCode)
                            .font(TsuyomiTheme.Typography.body)
                        if let field = warning.fieldName {
                            Text(field)
                                .font(TsuyomiTheme.Typography.caption)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        }
                    }
                }
                if warnings.count > TransferScreen.warningFoldThreshold {
                    Button(isExpandingWarnings ? "收起" : "展开其余 \(warnings.count - TransferScreen.warningFoldThreshold) 条") {
                        isExpandingWarnings.toggle()
                    }
                }
            }
        }
    }

    /// The picked file is read through a security-scoped resource and never copied anywhere else.
    private func load(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: url) else { return }
        await model.preview(bytes)
    }
}
