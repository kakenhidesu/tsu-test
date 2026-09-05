// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI
import UIKit

/// Which third of the surface the reader tapped. Volume-key paging does not exist on iOS, so tap
/// zones are the only paging affordance.
public enum ReaderTapZone: Sendable, Equatable {
    case previous
    case toggleChrome
    case next
}

/// Draws exactly the fragments the page plan measured. Nothing here re-measures: the view asks the
/// layout for the current page's range and renders that fragment sequence, so a rendered page can
/// never disagree with the plan a locator was resolved against.
public final class ReaderPageView: UIView {
    public var layout: ReaderTextLayout? {
        didSet { setNeedsDisplay() }
    }

    public var pageIndex = 0 {
        didSet { if pageIndex != oldValue { setNeedsDisplay() } }
    }

    /// Paged and dual-page render one and two columns of the same plan; scroll renders the whole
    /// document from the top of the visible range.
    public var flow: ReaderPresentation = .paged {
        didSet { if flow != oldValue { setNeedsDisplay() } }
    }

    public var horizontalMargin: CGFloat = 24
    public var textColor: UIColor = .label

    override public func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let columns = flow == .dualPage ? 2 : 1
        let columnWidth = (bounds.width - horizontalMargin * CGFloat(columns + 1)) / CGFloat(columns)
        for column in 0..<columns {
            let index = pageIndex + column
            guard layout.pages.indices.contains(index) else { break }
            let originX = horizontalMargin + CGFloat(column) * (columnWidth + horizontalMargin)
            drawPage(layout: layout, index: index, at: CGPoint(x: originX, y: 0), in: context)
        }
    }

    private func drawPage(layout: ReaderTextLayout, index: Int, at origin: CGPoint, in context: CGContext) {
        let page = layout.pages[index]
        let manager = layout.layoutManager
        guard let start = layout.contentStorage.location(
            layout.contentStorage.documentRange.location,
            offsetBy: page.location
        ) else { return }
        var offset: CGFloat = 0
        var first: CGFloat?
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fragmentStart = layout.contentStorage.offset(
                from: layout.contentStorage.documentRange.location,
                to: fragment.rangeInElement.location
            )
            guard fragmentStart < page.location + page.length else { return false }
            let top = fragment.layoutFragmentFrame.minY
            if first == nil { first = top }
            offset = top - (first ?? top)
            fragment.draw(at: CGPoint(x: origin.x, y: origin.y + offset), in: context)
            return true
        }
    }
}

/// Hosts the drawing view and routes taps. It owns no reading position: it reports the page the
/// reader moved to and lets the coordinator decide what that means semantically.
public struct ReaderSurface: UIViewRepresentable {
    private let layout: ReaderTextLayout
    private let pageIndex: Int
    private let flow: ReaderPresentation
    private let theme: ReaderTheme
    private let horizontalMargin: CGFloat
    private let onTap: (ReaderTapZone) -> Void

    public init(
        layout: ReaderTextLayout,
        pageIndex: Int,
        flow: ReaderPresentation,
        theme: ReaderTheme,
        horizontalMargin: CGFloat,
        onTap: @escaping (ReaderTapZone) -> Void
    ) {
        self.layout = layout
        self.pageIndex = pageIndex
        self.flow = flow
        self.theme = theme
        self.horizontalMargin = horizontalMargin
        self.onTap = onTap
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    public func makeUIView(context: Context) -> ReaderPageView {
        let view = ReaderPageView()
        view.isOpaque = true
        view.contentMode = .redraw
        let recognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(recognizer)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .staticText
        return view
    }

    public func updateUIView(_ view: ReaderPageView, context: Context) {
        context.coordinator.onTap = onTap
        view.layout = layout
        view.pageIndex = pageIndex
        view.flow = flow
        view.horizontalMargin = horizontalMargin
        view.backgroundColor = theme.backgroundColor
        view.textColor = theme.foregroundColor
        view.accessibilityLabel = accessibilityLabel(view)
        view.setNeedsDisplay()
    }

    private func accessibilityLabel(_ view: ReaderPageView) -> String {
        guard layout.pages.indices.contains(pageIndex) else { return "正文" }
        return "正文，第 \(pageIndex + 1) 页，共 \(layout.pages.count) 页"
    }

    
    @MainActor
    public final class Coordinator {
        var onTap: (ReaderTapZone) -> Void

        init(onTap: @escaping (ReaderTapZone) -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            let third = view.bounds.width / 3
            if x < third {
                onTap(.previous)
            } else if x > third * 2 {
                onTap(.next)
            } else {
                onTap(.toggleChrome)
            }
        }
    }
}

