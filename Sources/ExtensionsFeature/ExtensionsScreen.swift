// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI
import UIKit
import UniformTypeIdentifiers

/// Repository management. The official repository ships with the app and can only be paused; a
/// third-party one is subscribed by a link its maintainer published, and only after the reader has
/// looked at the identity and root fingerprint the catalog answered with.
public struct ExtensionsScreen: View {
    @ObservedObject private var model: ExtensionsModel
    private let openRepository: (RepositoryDescriptor) -> Void
    private let openPublisherKeys: () -> Void
    @State private var link = ""
    @State private var removing: RepositoryDescriptor?
    @FocusState private var linkFocused: Bool

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
        Form {
            if let code = model.failureCode {
                Section {
                    Text("上一步没有完成（\(code)）。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
                }
            }
            repositories
            subscribe
            if let pending = model.pendingApproval {
                confirmation(pending)
            }
        }
        .navigationTitle("仓库管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("发布者") { openPublisherKeys() }
            }
        }
        .confirmationDialog("移除这个仓库？", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("移除仓库", role: .destructive) {
                guard let descriptor = removing else { return }
                removing = nil
                Task { await model.removeRepository(descriptor.repositoryId) }
            }
            Button("取消", role: .cancel) { removing = nil }
        } message: {
            Text("移除仓库不会卸载已安装的来源，也不会删除其书籍或阅读进度。")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var repositories: some View {
        Section("仓库") {
            switch model.state {
            case .content(let content) where !content.repositories.isEmpty:
                ForEach(content.repositories, id: \.repositoryId) { descriptor in
                    repositoryRow(descriptor)
                }
            case .loading:
                ProgressView()
            default:
                Text("还没有添加仓库。")
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            }
        }
    }

    private func repositoryRow(_ descriptor: RepositoryDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openRepository(descriptor)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.isOfficial ? "官方仓库" : descriptor.repositoryId)
                            .font(TsuyomiTheme.Typography.body)
                            .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                        Text(descriptor.indexUrl.absoluteString)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                            .lineLimit(2)
                        Text("根密钥指纹：\(descriptor.rootKey.fingerprint.prefix(24))…")
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if descriptor.isOfficial {
                HStack {
                    Text(descriptor.enabled ? "官方仓库不可移除" : "官方仓库已停用")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    Spacer()
                    Toggle("启用", isOn: Binding(
                        get: { descriptor.enabled },
                        set: { enabled in Task { await model.setRepositoryEnabled(descriptor.repositoryId, enabled: enabled) } }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("启用官方仓库")
                }
            } else {
                Toggle("启用此仓库", isOn: Binding(
                    get: { descriptor.enabled },
                    set: { enabled in Task { await model.setRepositoryEnabled(descriptor.repositoryId, enabled: enabled) } }
                ))
                .font(TsuyomiTheme.Typography.supporting)
                Button("移除仓库", role: .destructive) { removing = descriptor }
                    .font(TsuyomiTheme.Typography.supporting)
            }
        }
        .padding(.vertical, 2)
    }

    private var subscribe: some View {
        Section {
            TextField("订阅链接", text: $link, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...5)
                .focused($linkFocused)
            Button("检查链接") {
                linkFocused = false
                Task { await model.probeRepository(link: link) }
            }
            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
        } header: {
            Text("添加第三方仓库")
        } footer: {
            Text("订阅链接由仓库维护者公布：目录地址后接 #repositoryId=…&keyId=…&publicKey=…。检查只读取目录，不会订阅。")
        }
    }

    /// The identity block: what the catalog says it is, and the fingerprint the link vouched for.
    /// Subscribing is the one act that trusts the listed publishers.
    private func confirmation(_ pending: PendingRepositoryApproval) -> some View {
        Section {
            LabeledContent("仓库标识", value: pending.index.repositoryId)
            VStack(alignment: .leading, spacing: 2) {
                Text("目录地址")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                Text(pending.descriptor.indexUrl.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("根密钥指纹")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                Text(pending.descriptor.rootKey.fingerprint)
                    .font(.system(.footnote, design: .monospaced))
            }
            LabeledContent("目录序号", value: "\(pending.index.sequence)")
            LabeledContent("包数量", value: "\(pending.index.packages.count)")
            ForEach(pending.index.publishers, id: \.keyId) { publisher in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                        Text(publisher.keyId)
                            .font(TsuyomiTheme.Typography.supporting)
                        if pending.newPublisherKeyIds.contains(publisher.keyId) {
                            TsuyomiStatusBadge("新的发布者密钥", tone: .warning)
                        }
                    }
                    Text(publisher.fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
            }
            Button("确认订阅") {
                link = ""
                Task { await model.approvePendingRepository() }
            }
            .disabled(model.isBusy)
            Button("取消此次检查", role: .cancel) { model.discardApproval() }
        } header: {
            Text("确认仓库身份")
        } footer: {
            Text("确认地址与根密钥指纹后，才会订阅此第三方仓库。扩展在应用进程内运行，信任这些发布者等同于信任它们的代码。")
        }
    }
}

/// The system's document picker, asked for a copy: the archive arrives in this app's own temporary
/// directory, so reading it never depends on a security-scoped grant. Every type is selectable
/// because an extension is admitted by verifying its bytes, not by its name. It is presented from an
/// inert anchor rather than from a SwiftUI sheet: the picker dismisses its own presentation once it
/// has answered, and inside a sheet that tears down the sheet instead, losing the answer with it.
public struct ArchivePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void

    public init(isPresented: Binding<Bool>, onPick: @escaping (URL) -> Void) {
        _isPresented = isPresented
        self.onPick = onPick
    }

    public func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    public func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    public func updateUIViewController(_ anchor: UIViewController, context: Context) {
        context.coordinator.owner = self
        guard isPresented, anchor.presentedViewController == nil, !context.coordinator.isShowing else {
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        context.coordinator.isShowing = true
        anchor.present(picker, animated: true)
    }

    @MainActor
    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var owner: ArchivePicker
        var isShowing = false

        init(owner: ArchivePicker) {
            self.owner = owner
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, urls.first)
        }

        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller, nil)
        }

        /// The archive is handed over only once the picker has left the screen, so the review sheet
        /// never asks to be presented while a dismissal is still running.
        private func finish(_ controller: UIDocumentPickerViewController, _ url: URL?) {
            isShowing = false
            owner.isPresented = false
            let deliver = owner.onPick
            guard let url else { return }
            guard let presenting = controller.presentingViewController else {
                deliver(url)
                return
            }
            presenting.dismiss(animated: true) { deliver(url) }
        }
    }
}
