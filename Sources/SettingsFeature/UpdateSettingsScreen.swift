// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// Periodic update checks and what they leave out. Off is the default; the constraint toggles are
/// only meaningful while a cadence is set.
public struct UpdateSettingsScreen: View {
    @ObservedObject private var model: UpdateSettingsModel

    public init(model: UpdateSettingsModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Picker("自动检查", selection: cadence) {
                    Text("关闭").tag(UpdateCadence.off)
                    Text("每 12 小时").tag(UpdateCadence.hours12)
                    Text("每天").tag(UpdateCadence.daily)
                    Text("每 3 天").tag(UpdateCadence.days3)
                    Text("每周").tag(UpdateCadence.weekly)
                }
            } footer: {
                Text("自动检查由系统在后台安排，实际时间由系统决定；随时可以在书架上手动检查。")
            }
            Section("条件") {
                Toggle("仅在非计费网络", isOn: unmeteredOnly)
                Toggle("仅在充电时", isOn: requiresCharging)
                Toggle("电量不低时", isOn: batteryNotLow)
            }
            .disabled(model.policy.cadence == .off)
            if !model.sources.isEmpty {
                Section {
                    ForEach(model.sources, id: \.sourceId) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { !model.excludedSourceIds.contains(source.sourceId.value) },
                            set: { enabled in Task { await model.setSourceExcluded(source.sourceId.value, excluded: !enabled) } }
                        ))
                    }
                } header: {
                    Text("按来源")
                }
            }
            if !model.excludedBooks.isEmpty {
                Section("已停止检查的书") {
                    ForEach(model.excludedBooks) { book in
                        HStack {
                            Text(book.title)
                            Spacer()
                            Button("恢复") { Task { await model.includeBook(book.identity) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("更新检查")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var cadence: Binding<UpdateCadence> {
        Binding(get: { model.policy.cadence }, set: { value in Task { await model.setCadence(value) } })
    }

    private var unmeteredOnly: Binding<Bool> {
        Binding(get: { model.policy.unmeteredOnly }, set: { value in Task { await model.setUnmeteredOnly(value) } })
    }

    private var requiresCharging: Binding<Bool> {
        Binding(get: { model.policy.requiresCharging }, set: { value in Task { await model.setRequiresCharging(value) } })
    }

    private var batteryNotLow: Binding<Bool> {
        Binding(get: { model.policy.batteryNotLow }, set: { value in Task { await model.setBatteryNotLow(value) } })
    }
}
