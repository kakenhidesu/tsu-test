// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol

/// Draws whatever the cover repository decided. It never receives a URL, so no view can start a
/// network request of its own or leak a source URL into the interface.
public struct CoverImage: View {
    private let state: CoverUiState

    public init(_ state: CoverUiState) {
        self.state = state
    }

    public var body: some View {
        Group {
            switch state {
            case .ready(let image), .staleReady(let image, _):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .loading(let fallback):
                placeholder(fallback, symbol: nil)
            case .absent(let fallback), .fallback(let fallback):
                placeholder(fallback, symbol: "book.closed")
            case .failed(_, let fallback):
                placeholder(fallback, symbol: "exclamationmark.triangle")
            }
        }
        .aspectRatio(TsuyomiTheme.Metrics.coverAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius))
        .accessibilityLabel(accessibilityLabel)
    }

    private func placeholder(_ fallback: FallbackSpec, symbol: String?) -> some View {
        ZStack {
            TsuyomiTheme.Palette.raisedSurface
            VStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                } else {
                    ProgressView()
                }
                Text(fallback.title)
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, TsuyomiTheme.Metrics.tightGutter)
            }
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .ready, .staleReady:
            return "封面"
        case .loading(let fallback):
            return "封面载入中，\(fallback.title)"
        case .absent(let fallback), .fallback(let fallback):
            return "无封面，\(fallback.title)"
        case .failed(let reason, let fallback):
            return "封面不可用（\(reason.rawValue)），\(fallback.title)"
        }
    }
}

/// One grid cell: cover, title, and at most one status badge. Selection is a visual state only; the
/// owner decides what selection means.
public struct TsuyomiCoverGridCard: View {
    private let title: String
    private let cover: CoverUiState
    private let badge: (text: LocalizedStringKey, tone: TsuyomiStatusTone)?
    private let isSelected: Bool
    private let action: () -> Void

    public init(
        title: String,
        cover: CoverUiState,
        badge: (text: LocalizedStringKey, tone: TsuyomiStatusTone)? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.cover = cover
        self.badge = badge
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
                CoverImage(cover)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            TsuyomiStatusBadge(badge.text, tone: badge.tone)
                                .padding(6)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius)
                            .strokeBorder(
                                isSelected ? TsuyomiTheme.Palette.accent : .clear,
                                lineWidth: 3
                            )
                    }
                Text(title)
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The source-home filter row. Selecting a capsule never fetches: the caller decides when a
/// selection becomes a request.
public struct TsuyomiFilterCapsules: View {
    private let filters: [SourceHomeFilter]
    private let selection: [String: String]
    private let onSelect: (String, String) -> Void
    @State private var expanded = false

    public init(
        filters: [SourceHomeFilter],
        selection: [String: String],
        onSelect: @escaping (String, String) -> Void
    ) {
        self.filters = filters
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
            ForEach(visibleFilters, id: \.id) { filter in
                VStack(alignment: .leading, spacing: 4) {
                    Text(filter.label)
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                            ForEach(filter.options, id: \.value) { option in
                                capsule(filter: filter, option: option)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
            }
            if filters.count > collapsedLimit {
                Button(expanded ? "收起筛选" : "展开全部筛选") {
                    expanded.toggle()
                }
                .font(TsuyomiTheme.Typography.caption)
                .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            }
        }
    }

    private var collapsedLimit: Int { 3 }

    private var visibleFilters: [SourceHomeFilter] {
        expanded ? filters : Array(filters.prefix(collapsedLimit))
    }

    private func capsule(filter: SourceHomeFilter, option: SourceHomeFilterOption) -> some View {
        let isSelected = selection[filter.id] == option.value
        return Button {
            onSelect(filter.id, option.value)
        } label: {
            Text(option.label)
                .font(TsuyomiTheme.Typography.caption)
                .padding(.horizontal, 12)
                .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                .background(
                    isSelected ? TsuyomiTheme.Palette.accent.opacity(0.18) : TsuyomiTheme.Palette.raisedSurface,
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected ? TsuyomiTheme.Palette.accent : TsuyomiTheme.Palette.primaryText
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.label)：\(option.label)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
