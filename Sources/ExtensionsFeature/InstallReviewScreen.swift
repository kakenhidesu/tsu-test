// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// The only confirmation point for any install, whether the archive came from a repository or from a
/// file the reader picked. Refusing here leaves the currently active version running.
public struct InstallReviewScreen: View {
    private let prepared: PreparedExtensionInstall
    @Binding private var consent: ExtensionInstallConsent
    private let isBusy: Bool
    private let onApprove: () -> Void
    private let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isDeltaExpanded = false

    public init(
        prepared: PreparedExtensionInstall,
        consent: Binding<ExtensionInstallConsent>,
        isBusy: Bool,
        onApprove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prepared = prepared
        _consent = consent
        self.isBusy = isBusy
        self.onApprove = onApprove
        self.onCancel = onCancel
    }

    /// Every consent the package needs must be given before the install button does anything.
    private var consentsGiven: Bool {
        (!prepared.requiresNonOfficialConsent || consent.nonOfficialExecution)
            && (!prepared.requiresMigrationConsent || consent.publisherMigration)
            && (!prepared.isDowngrade || consent.allowLocalDowngrade)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("扩展") {
                    LabeledContent("名称", value: prepared.candidate.manifest.displayName)
                    LabeledContent("标识", value: prepared.candidate.manifest.sourceId.value)
                    if let active = prepared.active {
                        LabeledContent(
                            "版本",
                            value: "\(active.manifest.version.original) → \(prepared.candidate.manifest.version.original)"
                        )
                    } else {
                        LabeledContent("版本", value: prepared.candidate.manifest.version.original)
                    }
                }
                Section {
                    Text(prepared.candidate.manifest.summary)
                        .font(TsuyomiTheme.Typography.supporting)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    TsuyomiStatusBadge(trustLabel, tone: trustTone)
                }
                Section {
                    DisclosureGroup(isExpanded: $isDeltaExpanded) {
                        LabeledContent("Key ID", value: prepared.candidate.manifest.publisherKeyId)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("发布者指纹")
                                .font(TsuyomiTheme.Typography.caption)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                            Text(prepared.candidate.publisherFingerprint)
                                .font(.system(.footnote, design: .monospaced))
                        }
                        if prepared.addedCapabilities.isEmpty {
                            Text(prepared.active == nil ? "按清单授予能力。" : "与已安装版本相比没有新增能力。")
                                .font(TsuyomiTheme.Typography.caption)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        } else {
                            ForEach(prepared.addedCapabilities, id: \.self) { capability in
                                Text(capability)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(TsuyomiTheme.Palette.warning)
                            }
                        }
                        ForEach(prepared.resourceLimitIncreases, id: \.limit) { increase in
                            LabeledContent(
                                LocalizedStringKey(increase.limit.rawValue),
                                value: "\(increase.activeValue) → \(increase.candidateValue)"
                            )
                        }
                    } label: {
                        Text("授权差异（新增 \(prepared.addedCapabilities.count) 项 · 上限提高 \(prepared.resourceLimitIncreases.count) 项）")
                            .font(TsuyomiTheme.Typography.supporting)
                    }
                }
                if prepared.requiresNonOfficialConsent || prepared.requiresMigrationConsent || prepared.isDowngrade {
                    Section("需要确认") {
                        if prepared.requiresNonOfficialConsent {
                            Toggle(isOn: Binding(
                                get: { consent.nonOfficialExecution },
                                set: { consent = ExtensionInstallConsent(
                                    allowLocalDowngrade: consent.allowLocalDowngrade,
                                    nonOfficialExecution: $0,
                                    publisherMigration: consent.publisherMigration
                                ) }
                            )) {
                                Text("我理解：非官方来源与本应用在同一进程中运行，信任它等同于信任它的代码。")
                                    .font(TsuyomiTheme.Typography.caption)
                                    .foregroundStyle(TsuyomiTheme.Palette.danger)
                            }
                        }
                        if prepared.requiresMigrationConsent {
                            Toggle(isOn: Binding(
                                get: { consent.publisherMigration },
                                set: { consent = ExtensionInstallConsent(
                                    allowLocalDowngrade: consent.allowLocalDowngrade,
                                    nonOfficialExecution: consent.nonOfficialExecution,
                                    publisherMigration: $0
                                ) }
                            )) {
                                Text("官方仓库声明这个包接替了另一位发布者签名的旧版本，我确认这次发布者变更。")
                                    .font(TsuyomiTheme.Typography.caption)
                                    .foregroundStyle(TsuyomiTheme.Palette.danger)
                            }
                        }
                        if prepared.isDowngrade {
                            Toggle(isOn: Binding(
                                get: { consent.allowLocalDowngrade },
                                set: { consent = ExtensionInstallConsent(
                                    allowLocalDowngrade: $0,
                                    nonOfficialExecution: consent.nonOfficialExecution,
                                    publisherMigration: consent.publisherMigration
                                ) }
                            )) {
                                Text("这是一个更低的版本，我确认回退。")
                                    .font(TsuyomiTheme.Typography.caption)
                                    .foregroundStyle(TsuyomiTheme.Palette.danger)
                            }
                        }
                    }
                }
            }
            .navigationTitle("安装审批")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("拒绝") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(prepared.active == nil ? "安装" : "更新") { onApprove() }
                        .disabled(isBusy || prepared.policyOutcome == .rejectedRevoked || !consentsGiven)
                }
            }
        }
    }

    private var trustLabel: LocalizedStringKey {
        switch prepared.policyOutcome {
        case .accepted: return "发布者已信任"
        case .requiresGrant: return "需要新的授权"
        case .rejectedRevoked: return "发布者或包已撤销"
        case .rejectedKeyRotation: return "密钥已更换，需要重新确认"
        case .rejectedDowngrade: return "版本回滚"
        case .rejectedReplay: return "重复的安装请求"
        }
    }

    private var trustTone: TsuyomiStatusTone {
        switch prepared.policyOutcome {
        case .accepted: return .positive
        case .requiresGrant: return .warning
        case .rejectedRevoked, .rejectedKeyRotation, .rejectedDowngrade, .rejectedReplay: return .danger
        }
    }
}
