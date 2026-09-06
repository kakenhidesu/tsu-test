// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import UIKit

/// Where one block starts in the laid-out string. Code-point offsets from a locator are converted to
/// UTF-16 offsets exactly once, here, so no other layer has to know the difference.
public struct BlockTextRange: Hashable, Sendable {
    public let blockIndex: Int
    public let location: Int
    public let length: Int
}

/// One page of the immutable page plan: the text range the page draws, and the fragment heights it
/// was measured from.
public struct ReaderPage: Hashable, Sendable {
    public let index: Int
    public let location: Int
    public let length: Int
    public let height: Double
}

/// Builds the single TextKit 2 stack that both measures and draws. "The measured object is the drawn
/// object" is a hard constraint: pagination reads the same `NSTextLayoutFragment` sequence the view
/// later renders, so a page boundary can never disagree with what appears on screen.
@MainActor
public final class ReaderTextLayout {
    public let contentStorage = NSTextContentStorage()
    public let layoutManager = NSTextLayoutManager()
    public private(set) var blockRanges: [BlockTextRange] = []
    public private(set) var pages: [ReaderPage] = []
    public private(set) var layoutKey: LayoutKey

    private let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var settings: ReaderSettings
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var textColor: UIColor = .label
    private var inkStroke: CGFloat = 0

    public init(document: ReaderDocument, settings: ReaderSettings) throws {
        self.settings = settings
        self.layoutKey = try ReaderTextLayout.key(settings: settings, width: 0)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        applyDocument(document)
    }

    /// Re-typesets for a new viewport or new typography. Anything that changes metrics produces a new
    /// layout key, and the caller must treat every page index from the previous key as stale.
    @discardableResult
    public func layout(width: CGFloat, height: CGFloat, settings: ReaderSettings) throws -> LayoutKey {
        let metricsChanged = width != self.width
            || settings.fontSize != self.settings.fontSize
            || settings.lineHeight != self.settings.lineHeight
            || settings.horizontalMargin != self.settings.horizontalMargin
            || settings.paragraphSpacing != self.settings.paragraphSpacing
        self.width = width
        self.height = height
        self.settings = settings
        if metricsChanged {
            container.size = CGSize(
                width: max(width - settings.horizontalMargin * 2, 1),
                height: CGFloat.greatestFiniteMagnitude
            )
            reapplyTypography()
        }
        layoutKey = try ReaderTextLayout.key(settings: settings, width: width)
        paginate()
        return layoutKey
    }

    /// The page that contains a block and code-point offset, or nil while the plan is empty.
    public func page(forBlockIndex blockIndex: Int, characterOffset: Int) -> ReaderPage? {
        guard let range = blockRanges.first(where: { $0.blockIndex == blockIndex }) else { return nil }
        let location = range.location + utf16Offset(in: blockIndex, codePointOffset: characterOffset)
        return pages.last { $0.location <= location } ?? pages.first
    }

    /// The block and code-point offset a page starts at, for capturing a semantic position.
    public func position(atPageIndex pageIndex: Int) -> (blockIndex: Int, characterOffset: Int)? {
        guard pages.indices.contains(pageIndex) else { return nil }
        let location = pages[pageIndex].location
        guard let range = blockRanges.last(where: { $0.location <= location }) else { return nil }
        let utf16Offset = location - range.location
        return (range.blockIndex, codePointOffset(in: range.blockIndex, utf16Offset: utf16Offset))
    }

    private func applyDocument(_ document: ReaderDocument) {
        let text = NSMutableAttributedString()
        var ranges: [BlockTextRange] = []
        for (index, block) in document.blocks.enumerated() {
            let start = text.length
            text.append(attributed(block))
            ranges.append(BlockTextRange(blockIndex: index, location: start, length: text.length - start))
        }
        blockRanges = ranges
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(text)
        }
    }

    private func reapplyTypography() {
        guard let storage = contentStorage.textStorage else { return }
        let replacement = NSMutableAttributedString()
        for range in blockRanges {
            let slice = storage.attributedSubstring(from: NSRange(location: range.location, length: range.length))
            let kind = slice.attribute(ReaderTextLayout.blockKindKey, at: 0, effectiveRange: nil) as? String
            replacement.append(styled(slice.string, kind: kind ?? "paragraph"))
        }
        contentStorage.performEditingTransaction {
            storage.setAttributedString(replacement)
        }
    }

    /// Accumulates the very fragments the view draws until the viewport height is exceeded; the first
    /// fragment that does not fit starts the next page.
    private func paginate() {
        guard height > 0 else {
            pages = []
            return
        }
        let start = layoutManager.documentRange.location
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var plan: [ReaderPage] = []
        var pageStart = 0
        var pageHeight: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fragmentHeight = fragment.layoutFragmentFrame.height
            let location = self.contentStorage.offset(
                from: self.layoutManager.documentRange.location,
                to: fragment.rangeInElement.location
            )
            if pageHeight > 0, pageHeight + fragmentHeight > self.height {
                plan.append(
                    ReaderPage(
                        index: plan.count,
                        location: pageStart,
                        length: location - pageStart,
                        height: Double(pageHeight)
                    )
                )
                pageStart = location
                pageHeight = 0
            }
            pageHeight += fragmentHeight
            return true
        }
        let total = contentStorage.textStorage?.length ?? pageStart
        if total > pageStart || plan.isEmpty {
            plan.append(
                ReaderPage(
                    index: plan.count,
                    location: pageStart,
                    length: max(total - pageStart, 0),
                    height: Double(pageHeight)
                )
            )
        }
        pages = plan
    }

    private func attributed(_ block: ReaderBlock) -> NSAttributedString {
        switch block {
        case .paragraph(let value): return styled(value.text + "\n", kind: "paragraph")
        case .heading(let value): return styled(value.text + "\n", kind: "heading\(value.level)")
        case .quote(let value): return styled(value.text + "\n", kind: "quote")
        case .divider: return styled("\u{2014}\u{2014}\u{2014}\n", kind: "divider")
        case .image(let value): return styled((value.alternateText ?? "") + "\n", kind: "image")
        case .post(let value): return styled(value.authorName + "\n", kind: "post")
        }
    }

    private func styled(_ text: String, kind: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = settings.lineHeight
        paragraph.paragraphSpacing = settings.paragraphSpacing
        paragraph.alignment = kind.hasPrefix("heading") ? .left : .natural
        if kind == "quote" { paragraph.firstLineHeadIndent = 16; paragraph.headIndent = 16 }
        let size = kind.hasPrefix("heading") ? settings.fontSize * 1.25 : settings.fontSize
        let weight: UIFont.Weight = kind.hasPrefix("heading") ? .semibold : .regular
        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: weight),
                .paragraphStyle: paragraph,
                .foregroundColor: textColor,
                .strokeColor: textColor,
                .strokeWidth: inkStroke,
                ReaderTextLayout.blockKindKey: kind
            ]
        )
    }

    /// The theme's ink. Colour is not a metric: it changes what a page looks like and never where a
    /// page ends, so it is applied over the whole string instead of being folded into the layout key,
    /// and a theme switch still does not repaginate. The stroke is ink too — it is drawn around the
    /// same glyphs at the same advances, which is what lets a heavier theme keep every page boundary
    /// where a heavier face would not. Drawing takes its colour from the string, so without this the
    /// text is whatever TextKit defaults to — black, invisible on a dark theme.
    public func apply(textColor: UIColor, inkStroke: CGFloat) {
        guard textColor != self.textColor || inkStroke != self.inkStroke else { return }
        self.textColor = textColor
        self.inkStroke = inkStroke
        guard let storage = contentStorage.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttributes(
            [.foregroundColor: textColor, .strokeColor: textColor, .strokeWidth: inkStroke],
            range: NSRange(location: 0, length: storage.length)
        )
        storage.endEditing()
    }

    private func utf16Offset(in blockIndex: Int, codePointOffset: Int) -> Int {
        guard let text = blockText(blockIndex) else { return 0 }
        let scalars = Array(text.unicodeScalars.prefix(max(codePointOffset, 0)))
        return String(String.UnicodeScalarView(scalars)).utf16.count
    }

    private func codePointOffset(in blockIndex: Int, utf16Offset: Int) -> Int {
        guard let text = blockText(blockIndex) else { return 0 }
        let units = Array(text.utf16.prefix(max(utf16Offset, 0)))
        return String(utf16CodeUnits: units, count: units.count).unicodeScalars.count
    }

    private func blockText(_ blockIndex: Int) -> String? {
        guard let storage = contentStorage.textStorage,
              let range = blockRanges.first(where: { $0.blockIndex == blockIndex }),
              range.location + range.length <= storage.length else { return nil }
        return storage.attributedSubstring(
            from: NSRange(location: range.location, length: range.length)
        ).string
    }

    /// A colour-only change must not change this key, or every theme switch would repaginate.
    static func key(settings: ReaderSettings, width: CGFloat) throws -> LayoutKey {
        try LayoutKey(
            "w=\(Int(width.rounded()));f=\(settings.fontSize);l=\(settings.lineHeight);"
                + "m=\(settings.horizontalMargin);p=\(settings.paragraphSpacing);flow=\(settings.flow.rawValue)"
        )
    }

    static let blockKindKey = NSAttributedString.Key("org.tsuyomi.blockKind")
}
