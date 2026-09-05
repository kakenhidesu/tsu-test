// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiSource
import TsuyomiUI

/// The only confirmation point for any install, whether the archive came from a repository or from a
/// file the reader picked. Refusing here leaves the currently active version running.
public struct InstallReviewScreen: View {
    private let prepared: PreparedExtensionInstall
    private let isBusy: Bool
    private let onApprove: () -> Void
    private let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    public init(
        prepared: PreparedExtensionInstall,
        isBusy: Bool,
        onApprove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prepared = prepared
        self.isBusy = isBusy
        self.onApprove = onApprove
        self.onCancel = onCancel
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
                Section("发布者") {
                    LabeledContent("Key ID", value: prepared.candidate.manifest.publisherKeyId)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("指纹")
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        Text(prepared.candidate.publisherFingerprint)
                            .font(.system(.footnote, design: .monospaced))
                    }
                    TsuyomiStatusBadge(trustLabel, tone: trustTone)
                }
                if prepared.addedCapabilities.isEmpty {
                    Section("能力") {
                        Text(prepared.active == nil ? "按下方清单授予能力。" : "与已安装版本相比没有新增能力。")
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    }
                } else {
                    Section("新增能力") {
                        ForEach(prepared.addedCapabilities, id: \.self) { capability in
                            Text(capability)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(TsuyomiTheme.Palette.warning)
                        }
                    }
                }
                if !prepared.resourceLimitIncreases.isEmpty {
                    Section("资源上限提高") {
                        ForEach(prepared.resourceLimitIncreases, id: \.limit) { increase in
                            LabeledContent(
                                LocalizedStringKey(increase.limit.rawValue),
                                value: "\(increase.activeValue) → \(increase.candidateValue)"
                            )
                        }
                    }
                }
                Section {
                    Text("扩展在应用进程内运行，QuickJS 不是进程级沙箱；同意安装等同于信任这份代码。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.danger)
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
                    // Approving does not dismiss: this sheet is presented off the pending install, so
                    // dismissing here would clear it before the approval has been acted on. The model
                    // clears it when the install settles, which closes the sheet.
                    Button(prepared.active == nil ? "安装" : "更新") { onApprove() }
                        .disabled(isBusy || prepared.policyOutcome == .rejectedRevoked)
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
