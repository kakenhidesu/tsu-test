// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI
import UIKit
import UniformTypeIdentifiers

enum ExtensionsSegment: String, CaseIterable, Hashable {
    case installed
    case repositories

    var title: LocalizedStringKey {
        switch self {
        case .installed: return "已安装"
        case .repositories: return "仓库"
        }
    }
}

public struct ExtensionsScreen: View {
    @ObservedObject private var model: ExtensionsModel
    private let openRepository: (RepositoryDescriptor) -> Void
    private let openPublisherKeys: () -> Void
    @State private var segment: ExtensionsSegment = .installed
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var pickedArchive: URL?
    @State private var base = ""

    public init(
        model: ExtensionsModel,
        openRepository: @escaping (RepositoryDescriptor) -> Void,
        openPublisherKeys: @escaping () -> Void
    ) {
        self.model = model
        self.openRepository = openRepository
        self.openPublisherKeys = openPublisherKeys
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("分段", selection: $segment) {
                ForEach(ExtensionsSegment.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(TsuyomiTheme.Metrics.gutter)
            .sheet(isPresented: $isImporting, onDismiss: {
                guard let url = pickedArchive else { return }
                pickedArchive = nil
                Task { await model.importPackage(at: url) }
            }) {
                ArchivePicker { url in
                    pickedArchive = url
                    isImporting = false
                }
            }
            if let status = model.importStatus {
                Text(status)
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            }
            if let code = model.failureCode {
                Text("上一步没有完成（\(code)）。")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            }
            if model.isBusy {
                ProgressView()
                    .padding(.bottom, TsuyomiTheme.Metrics.tightGutter)
            }
            StateView(model.state, retry: { Task { await model.load() } }) { content in
                List {
                    switch segment {
                    case .installed: installedRows(content.installed)
                    case .repositories: repositoryRows(content.repositories)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("扩展")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("发布者") { openPublisherKeys() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("添加") {
                    Button("添加仓库") { isAdding = true }
                    Button("导入 .hxp 文件") { isImporting = true }
                }
                .disabled(model.isBusy)
            }
        }
        .alert("添加仓库", isPresented: $isAdding) {
            TextField("https://example.org/tsuyomi", text: $base)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { base = "" }
            Button("读取索引") {
                let typed = base
                base = ""
                Task { await model.probeRepository(base: typed) }
            }
        } message: {
            Text("仓库是一个 HTTPS 基址，其下托管 index.json 与 index.sig。")
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingApproval != nil || model.pendingInstall != nil },
                set: { presented in
                    guard !presented else { return }
                    model.discardApproval()
                    model.discardPendingInstall()
                }
            )
        ) {
            if let pending = model.pendingApproval {
                RepositoryApprovalSheet(pending: pending, model: model)
            } else if let prepared = model.pendingInstall {
                InstallReviewScreen(
                    prepared: prepared,
                    isBusy: model.isBusy,
                    onApprove: { Task { await model.approvePendingInstall() } },
                    onCancel: { model.discardPendingInstall() }
                )
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private func installedRows(_ installed: [InstalledSource]) -> some View {
        if installed.isEmpty {
            Text("还没有安装任何扩展。")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        } else {
            ForEach(installed, id: \.sourceId) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(TsuyomiTheme.Typography.body)
                    Text("\(source.version.original) · \(source.publisherFingerprint.prefix(16))")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
                .swipeActions {
                    Button("卸载", role: .destructive) {
                        Task { await model.uninstall(source.sourceId) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func repositoryRows(_ repositories: [RepositoryDescriptor]) -> some View {
        if repositories.isEmpty {
            Text("还没有添加仓库。")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        } else {
            ForEach(repositories, id: \.repositoryId) { descriptor in
                Button {
                    openRepository(descriptor)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.repositoryId)
                            .font(TsuyomiTheme.Typography.body)
                            .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                        Text(descriptor.base.canonical)
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: TsuyomiTheme.Metrics.minimumTouchTarget, alignment: .leading)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("移除", role: .destructive) {
                        Task { await model.removeRepository(descriptor.repositoryId) }
                    }
                }
            }
        }
    }
}

/// The system's document picker, asked for a copy: the archive arrives in this app's own temporary
/// directory, so reading it never depends on a security-scoped grant. Every type is selectable
/// because an extension is admitted by verifying its bytes, not by its name.
struct ArchivePicker: UIViewControllerRepresentable {
    let onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onFinish: (URL?) -> Void

        init(onFinish: @escaping (URL?) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(nil)
        }
    }
}

/// Approving a repository is approving its publisher. The fingerprint and the risk of running third
/// party code in this process are both stated here, because this is the last screen before trust.
struct RepositoryApprovalSheet: View {
    let pending: PendingRepositoryApproval
    @ObservedObject var model: ExtensionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("仓库") {
                    LabeledContent("标识", value: pending.index.repositoryId)
                    LabeledContent("名称", value: pending.index.displayName)
                    Text(pending.index.summary)
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    LabeledContent("包数量", value: "\(pending.index.packages.count)")
                }
                Section("发布者") {
                    LabeledContent("Key ID", value: pending.index.publisher.keyId)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("公钥指纹")
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        Text(pending.index.publisher.fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                    }
                    if pending.isNewPublisherKey {
                        TsuyomiStatusBadge("新的发布者密钥", tone: .warning)
                    }
                }
                Section {
                    Text("扩展在应用进程内运行，QuickJS 不是进程级沙箱；信任这个发布者等同于信任它的代码。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
                }
            }
            .navigationTitle("确认发布者")
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
}
