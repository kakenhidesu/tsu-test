// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Top bar, content, and bottom slot with one consistent background and safe-area treatment.
public struct TsuyomiScaffold<Content: View, Bottom: View>: View {
    private let title: LocalizedStringKey
    private let content: Content
    private let bottom: Bottom

    public init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottom: () -> Bottom = { EmptyView() }
    ) {
        self.title = title
        self.content = content()
        self.bottom = bottom()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TsuyomiTheme.Palette.groupedSurface)
            .navigationTitle(title)
            .safeAreaInset(edge: .bottom) { bottom }
    }
}

/// Explicit paging: the next page is fetched only when the reader asks for it.
public struct PaginationBar: View {
    private let page: Int
    private let hasPrevious: Bool
    private let hasNext: Bool
    private let onPrevious: () -> Void
    private let onNext: () -> Void

    public init(
        page: Int,
        hasPrevious: Bool,
        hasNext: Bool,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) {
        self.page = page
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.onPrevious = onPrevious
        self.onNext = onNext
    }

    public var body: some View {
        HStack {
            Button(action: onPrevious) {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(!hasPrevious)
            Spacer()
            Text("第 \(page) 页")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                .accessibilityLabel("当前第 \(page) 页")
            Spacer()
            Button(action: onNext) {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(!hasNext)
        }
        .labelStyle(.titleAndIcon)
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .background(.bar)
    }
}

/// A segmented picker that always carries a semantic label, so VoiceOver announces what is being
/// segmented rather than only the selected value.
public struct SegmentedSelector<Value: Hashable>: View {
    private let label: LocalizedStringKey
    private let options: [(value: Value, title: LocalizedStringKey)]
    @Binding private var selection: Value

    public init(
        label: LocalizedStringKey,
        options: [(value: Value, title: LocalizedStringKey)],
        selection: Binding<Value>
    ) {
        self.label = label
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].title).tag(options[index].value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(label)
    }
}

/// One settings row: title, optional supporting text, and exactly one control.
public struct SettingsRow<Control: View>: View {
    private let title: LocalizedStringKey
    private let supporting: LocalizedStringKey?
    private let control: Control

    public init(
        title: LocalizedStringKey,
        supporting: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.supporting = supporting
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TsuyomiTheme.Metrics.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TsuyomiTheme.Typography.body)
                if let supporting {
                    Text(supporting)
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
            }
            Spacer(minLength: TsuyomiTheme.Metrics.tightGutter)
            control
        }
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
    }
}

public enum TsuyomiStatusTone: Sendable {
    case neutral
    case positive
    case warning
    case danger

    var tint: Color {
        switch self {
        case .neutral: return TsuyomiTheme.Palette.secondaryText
        case .positive: return TsuyomiTheme.Palette.success
        case .warning: return TsuyomiTheme.Palette.warning
        case .danger: return TsuyomiTheme.Palette.danger
        }
    }
}

public struct TsuyomiStatusBadge: View {
    private let text: LocalizedStringKey
    private let tone: TsuyomiStatusTone

    public init(_ text: LocalizedStringKey, tone: TsuyomiStatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(TsuyomiTheme.Typography.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tone.tint)
            .accessibilityLabel(text)
    }
}

public struct TsuyomiTabs<Value: Hashable>: View {
    private let tabs: [(value: Value, title: LocalizedStringKey)]
    @Binding private var selection: Value

    public init(tabs: [(value: Value, title: LocalizedStringKey)], selection: Binding<Value>) {
        self.tabs = tabs
        self._selection = selection
    }

    /// Equal-width tabs: the four source-home destinations must not reflow as their titles change.
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { index in
                let tab = tabs[index]
                Button {
                    selection = tab.value
                } label: {
                    Text(tab.title)
                        .font(TsuyomiTheme.Typography.supporting)
                        .frame(maxWidth: .infinity, minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                        .foregroundStyle(
                            selection == tab.value
                                ? TsuyomiTheme.Palette.accent
                                : TsuyomiTheme.Palette.secondaryText
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab.value ? [.isSelected, .isButton] : .isButton)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selection == tab.value ? TsuyomiTheme.Palette.accent : .clear)
                        .frame(height: 2)
                }
            }
        }
        .background(TsuyomiTheme.Palette.surface)
    }
}

public struct TsuyomiNavigationCard<Trailing: View>: View {
    private let title: LocalizedStringKey
    private let supporting: LocalizedStringKey?
    private let systemImage: String
    private let trailing: Trailing
    private let action: () -> Void

    public init(
        title: LocalizedStringKey,
        supporting: LocalizedStringKey? = nil,
        systemImage: String,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.supporting = supporting
        self.systemImage = systemImage
        self.action = action
        self.trailing = trailing()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(TsuyomiTheme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    if let supporting {
                        Text(supporting)
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    }
                }
                Spacer(minLength: TsuyomiTheme.Metrics.tightGutter)
                trailing
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
            }
            .padding(TsuyomiTheme.Metrics.gutter)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .background(TsuyomiTheme.Palette.surface, in: RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius))
        }
        .buttonStyle(.plain)
    }
}
