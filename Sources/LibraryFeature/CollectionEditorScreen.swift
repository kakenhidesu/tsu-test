// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

/// Creating a collection. A manual one only needs a name; a smart one is authored with real controls
/// and refuses to save while the rule the controls describe is invalid.
public struct CollectionEditorScreen: View {
    @ObservedObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SmartRuleDraft()
    @State private var isSmart = false
    @State private var violations: [SmartRuleViolation] = []
    @State private var isConfirmingDiscard = false

    public init(model: LibraryModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $draft.title)
                    Toggle("智能收藏夹", isOn: $isSmart)
                }
                if isSmart {
                    Section("匹配方式") {
                        Picker("匹配方式", selection: $draft.combinator) {
                            Text("全部条件").tag(MatchMode.all)
                            Text("任一条件").tag(MatchMode.any)
                        }
                        .pickerStyle(.segmented)
                    }
                    ForEach($draft.predicates) { $predicate in
                        Section {
                            predicateRows($predicate)
                            if let message = violation(for: predicate) {
                                Text(message)
                                    .font(TsuyomiTheme.Typography.caption)
                                    .foregroundStyle(TsuyomiTheme.Palette.danger)
                            }
                        }
                    }
                    Section {
                        Button("添加条件") { draft.predicates.append(SmartPredicateDraft()) }
                        if draft.predicates.count > 1 {
                            Button("删除最后一个条件", role: .destructive) {
                                draft.predicates.removeLast()
                            }
                        }
                    }
                }
                if let root = violations.first(where: { $0.path == "root" }) {
                    Section {
                        Text(CollectionEditorScreen.message(root.code))
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.danger)
                    }
                }
            }
            .navigationTitle("新建收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        if hasUnsavedWork {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("放弃这个收藏夹？", isPresented: $isConfirmingDiscard) {
                Button("放弃", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("你填写的内容还没有保存。")
            }
        }
    }

    private var hasUnsavedWork: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            || draft.predicates.contains { !$0.terms.isEmpty }
    }

    @ViewBuilder
    private func predicateRows(_ predicate: Binding<SmartPredicateDraft>) -> some View {
        Picker("条件", selection: predicate.kind) {
            ForEach(SmartPredicateDraft.Kind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        Toggle("取反", isOn: predicate.isNegated)
        if predicate.wrappedValue.kind.takesTerms {
            TextField("用逗号分隔", text: predicate.terms)
                .autocorrectionDisabled()
        }
        if predicate.wrappedValue.kind.takesDays {
            Stepper("最近 \(predicate.wrappedValue.days) 天", value: predicate.days, in: 1...3650)
        }
        if predicate.wrappedValue.kind == .statusIn {
            ForEach(PublicationStatus.allCases, id: \.self) { status in
                Toggle(
                    CollectionEditorScreen.title(status),
                    isOn: binding(predicate.statuses, status)
                )
            }
        }
        if predicate.wrappedValue.kind == .progressIn {
            ForEach(ProgressState.allCases, id: \.self) { state in
                Toggle(
                    CollectionEditorScreen.title(state),
                    isOn: binding(predicate.progress, state)
                )
            }
        }
    }

    private func binding<Value: Hashable>(
        _ set: Binding<Set<Value>>,
        _ member: Value
    ) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(member) },
            set: { included in
                if included {
                    set.wrappedValue.insert(member)
                } else {
                    set.wrappedValue.remove(member)
                }
            }
        )
    }

    private func violation(for predicate: SmartPredicateDraft) -> String? {
        guard let index = draft.predicates.firstIndex(of: predicate) else { return nil }
        return violations
            .first { $0.path.hasPrefix("root[\(index)]") }
            .map { CollectionEditorScreen.message($0.code) }
    }

    private func save() {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard isSmart else {
            Task {
                await model.createManualCollection(named: title)
                dismiss()
            }
            return
        }
        switch draft.compile() {
        case .failure(let found):
            violations = found
        case .success(let rule):
            violations = []
            Task {
                await model.createSmartCollection(named: title, rule: rule)
                dismiss()
            }
        }
    }

    private static func message(_ code: String) -> String {
        switch code {
        case "invalid-term-count": return "这个条件还没有填写可用的内容。"
        case "invalid-text-length": return "有一项内容过长。"
        case "invalid-time-window": return "天数超出允许范围。"
        case "empty-rule": return "至少需要一个可用条件。"
        case "max-depth", "max-nodes": return "条件太多，请精简。"
        default: return "这个条件无法保存。"
        }
    }

    private static func title(_ status: PublicationStatus) -> String {
        switch status {
        case .unknown: return "未知"
        case .ongoing: return "连载中"
        case .completed: return "已完结"
        case .hiatus: return "暂停"
        case .cancelled: return "已取消"
        }
    }

    private static func title(_ state: ProgressState) -> String {
        switch state {
        case .unstarted: return "未开始"
        case .reading: return "在读"
        case .finished: return "已读完"
        }
    }
}
