// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// A tag as a tinted pill. The colour is derived from the tag itself, so the same tag is the same
/// colour everywhere and on every launch without anything having to be stored; it carries no meaning
/// beyond telling one tag from the next at a glance. The tints are system colours, so they hold up
/// in both appearances.
public struct TsuyomiTagBadge: View {
    private static let tints: [Color] = [
        .blue, .purple, .pink, .orange, .green, .teal, .indigo, .cyan
    ]

    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(TsuyomiTheme.Typography.badge)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel(text)
    }

    /// A stable hash of the scalars rather than `hashValue`, which is seeded per process and would
    /// recolour every tag on each launch.
    private var tint: Color {
        var value: UInt64 = 5381
        for scalar in text.unicodeScalars {
            value = value &* 33 &+ UInt64(scalar.value)
        }
        return Self.tints[Int(value % UInt64(Self.tints.count))]
    }
}
