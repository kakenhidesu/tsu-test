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

    /// Reports the page index that has actually been painted. A preview may only be committed
    /// against a page the reader has seen, so the witness comes from drawing, not from state.
    public var onPageDrawn: ((Int) -> Void)?

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
        onPageDrawn?(pageIndex)
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

/// Carries the page view and slides one page off as the next comes on. Turning a page is the reader's
/// only continuous feedback that anything happened, and a hard cut reads as a glitch rather than a
/// turn. The outgoing page is a snapshot, so only one page is ever drawn.
public final class ReaderPagingView: UIView {
    public let page = ReaderPageView()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(page)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a storyboard view") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard page.layer.animationKeys() == nil else { return }
        page.frame = bounds
    }

    /// `direction` is +1 when the next page arrives from the trailing edge and -1 for the previous
    /// one. Anything that is not a single step — a chapter change, a re-pagination, an accessibility
    /// setting that asks for less motion — is set without animating.
    func show(pageIndex: Int, direction: Int) {
        guard direction != 0, !UIAccessibility.isReduceMotionEnabled, bounds.width > 0,
              let outgoing = page.snapshotView(afterScreenUpdates: false) else {
            page.pageIndex = pageIndex
            return
        }
        outgoing.frame = bounds
        addSubview(outgoing)
        page.pageIndex = pageIndex
        page.frame = bounds.offsetBy(dx: CGFloat(direction) * bounds.width, dy: 0)
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.page.frame = self.bounds
            outgoing.frame = self.bounds.offsetBy(dx: CGFloat(-direction) * self.bounds.width, dy: 0)
        } completion: { _ in
            outgoing.removeFromSuperview()
        }
    }
}

/// Hosts the drawing view and routes taps and swipes. It owns no reading position: it reports the
/// page the reader moved to and lets the coordinator decide what that means semantically.
public struct ReaderSurface: UIViewRepresentable {
    private let layout: ReaderTextLayout
    private let pageIndex: Int
    private let flow: ReaderPresentation
    private let theme: ReaderTheme
    private let horizontalMargin: CGFloat
    private let onTap: (ReaderTapZone) -> Void
    private let onPageDrawn: (Int) -> Void

    public init(
        layout: ReaderTextLayout,
        pageIndex: Int,
        flow: ReaderPresentation,
        theme: ReaderTheme,
        horizontalMargin: CGFloat,
        onTap: @escaping (ReaderTapZone) -> Void,
        onPageDrawn: @escaping (Int) -> Void
    ) {
        self.onPageDrawn = onPageDrawn
        self.layout = layout
        self.pageIndex = pageIndex
        self.flow = flow
        self.theme = theme
        self.horizontalMargin = horizontalMargin
        self.onTap = onTap
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    public func makeUIView(context: Context) -> ReaderPagingView {
        let container = ReaderPagingView()
        container.page.isOpaque = true
        container.page.contentMode = .redraw
        container.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        )
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSwipe(_:))
            )
            swipe.direction = direction
            container.addGestureRecognizer(swipe)
        }
        container.isAccessibilityElement = true
        container.accessibilityTraits = .staticText
        return container
    }

    public func updateUIView(_ container: ReaderPagingView, context: Context) {
        context.coordinator.onTap = onTap
        let view = container.page
        let turned = context.coordinator.turn(to: pageIndex, key: layout.layoutKey, flow: flow)
        view.onPageDrawn = onPageDrawn
        view.layout = layout
        view.flow = flow
        view.horizontalMargin = horizontalMargin
        view.backgroundColor = theme.backgroundColor
        container.backgroundColor = theme.backgroundColor
        layout.apply(textColor: theme.foregroundColor)
        container.accessibilityLabel = accessibilityLabel()
        container.show(pageIndex: pageIndex, direction: turned)
        view.setNeedsDisplay()
    }

    private func accessibilityLabel() -> String {
        guard layout.pages.indices.contains(pageIndex) else { return "正文" }
        return "正文，第 \(pageIndex + 1) 页，共 \(layout.pages.count) 页"
    }

    @MainActor
    public final class Coordinator {
        var onTap: (ReaderTapZone) -> Void
        private var shown: (index: Int, key: LayoutKey, flow: ReaderPresentation)?

        init(onTap: @escaping (ReaderTapZone) -> Void) {
            self.onTap = onTap
        }

        /// Which way the page moved, and only when it moved by one page of the same plan. A new
        /// chapter, a re-pagination or a flow change replaces the page rather than turning it.
        func turn(to index: Int, key: LayoutKey, flow: ReaderPresentation) -> Int {
            defer { shown = (index, key, flow) }
            guard let shown, shown.key == key, shown.flow == flow else { return 0 }
            let step = index - shown.index
            return abs(step) == 1 ? (step > 0 ? 1 : -1) : 0
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

        /// Swiping is the gesture a reader reaches for first; the tap zones stay because they are the
        /// only affordance that works one-handed at the edge of a large screen.
        @objc func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            onTap(recognizer.direction == .left ? .next : .previous)
        }
    }
}

