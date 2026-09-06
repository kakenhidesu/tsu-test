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

/// One page as a view controller, so `UIPageViewController` can carry it. It holds only the index it
/// draws: the page plan and the reading position live above it.
final class ReaderPageController: UIViewController {
    let index: Int
    let page = ReaderPageView()

    init(index: Int) {
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a storyboard controller") }

    override func loadView() {
        page.isOpaque = true
        page.contentMode = .redraw
        page.pageIndex = index
        view = page
    }
}

/// Hosts the pages and turns them. `UIPageViewController` draws both turns the reader can choose:
/// its scroll style is the slide, its page-curl style is the curl, and each is draggable rather than
/// only tappable. The style is fixed when that controller is created, so changing the setting
/// rebuilds the child instead of mutating it.
public final class ReaderPagingController: UIViewController {
    /// What the reader is looking at, as far as this controller has been told.
    private(set) var shownIndex = 0
    private(set) var transitionStyle: ReaderPageTransition = .slide
    var pageCount = 0
    var configure: ((ReaderPageView) -> Void)?
    var onTurn: ((Int) -> Void)?
    var onTap: ((ReaderTapZone) -> Void)?

    private var pages: UIPageViewController?

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        rebuild()
    }

    /// Reduce Motion turns every choice into the immediate one. A curl is a large, unavoidable
    /// movement, and that setting is to be respected rather than styled around.
    private var effectiveStyle: ReaderPageTransition {
        UIAccessibility.isReduceMotionEnabled ? .immediate : transitionStyle
    }

    func apply(style: ReaderPageTransition, index: Int, pageCount: Int) {
        self.pageCount = pageCount
        let styleChanged = style != transitionStyle
        transitionStyle = style
        guard !styleChanged, pages != nil else {
            shownIndex = index
            rebuild()
            return
        }
        guard index != shownIndex else {
            visiblePages().forEach(refresh)
            return
        }
        let forward = index > shownIndex
        let animated = effectiveStyle != .immediate && abs(index - shownIndex) == 1
        shownIndex = index
        pages?.setViewControllers(
            [makePage(index)],
            direction: forward ? .forward : .reverse,
            animated: animated
        )
    }

    private func visiblePages() -> [ReaderPageView] {
        (pages?.viewControllers ?? []).compactMap { ($0 as? ReaderPageController)?.page }
    }

    private func rebuild() {
        pages?.willMove(toParent: nil)
        pages?.view.removeFromSuperview()
        pages?.removeFromParent()
        let controller = UIPageViewController(
            transitionStyle: effectiveStyle == .curl ? .pageCurl : .scroll,
            navigationOrientation: .horizontal
        )
        controller.delegate = self
        // No data source means no interactive turn, which is what the immediate choice asks for: the
        // page changes when the reader taps, with no gesture that could animate it.
        controller.dataSource = effectiveStyle == .immediate ? nil : self
        controller.setViewControllers([makePage(shownIndex)], direction: .forward, animated: false)
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        // The curl style brings its own edge taps, which would turn a page the tap zones have already
        // turned. Its pan stays: dragging the corner is the whole point of a curl.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
        pages = controller
    }

    private func makePage(_ index: Int) -> ReaderPageController {
        let controller = ReaderPageController(index: index)
        refresh(controller.page)
        return controller
    }

    private func refresh(_ page: ReaderPageView) {
        configure?(page)
        page.setNeedsDisplay()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: view).x
        let third = view.bounds.width / 3
        if x < third {
            onTap?(.previous)
        } else if x > third * 2 {
            onTap?(.next)
        } else {
            onTap?(.toggleChrome)
        }
    }
}

extension ReaderPagingController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    public func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let current = viewController as? ReaderPageController, current.index > 0 else { return nil }
        return makePage(current.index - 1)
    }

    public func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let current = viewController as? ReaderPageController,
              current.index + 1 < pageCount else { return nil }
        return makePage(current.index + 1)
    }

    /// A drag that settled is the reader moving their position, so it is reported upwards; one that
    /// was let go of and sprang back is not.
    public func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed,
              let current = pageViewController.viewControllers?.first as? ReaderPageController else { return }
        shownIndex = current.index
        onTurn?(current.index)
    }
}

/// Hosts the paging controller and routes taps. It owns no reading position: it reports the page the
/// reader moved to and lets the model decide what that means semantically.
public struct ReaderSurface: UIViewControllerRepresentable {
    private let layout: ReaderTextLayout
    private let pageIndex: Int
    private let flow: ReaderPresentation
    private let theme: ReaderTheme
    private let transition: ReaderPageTransition
    private let horizontalMargin: CGFloat
    private let onTap: (ReaderTapZone) -> Void
    private let onTurn: (Int) -> Void
    private let onPageDrawn: (Int) -> Void

    public init(
        layout: ReaderTextLayout,
        pageIndex: Int,
        flow: ReaderPresentation,
        theme: ReaderTheme,
        transition: ReaderPageTransition,
        horizontalMargin: CGFloat,
        onTap: @escaping (ReaderTapZone) -> Void,
        onTurn: @escaping (Int) -> Void,
        onPageDrawn: @escaping (Int) -> Void
    ) {
        self.layout = layout
        self.pageIndex = pageIndex
        self.flow = flow
        self.theme = theme
        self.transition = transition
        self.horizontalMargin = horizontalMargin
        self.onTap = onTap
        self.onTurn = onTurn
        self.onPageDrawn = onPageDrawn
    }

    public func makeUIViewController(context: Context) -> ReaderPagingController {
        ReaderPagingController()
    }

    public func updateUIViewController(_ controller: ReaderPagingController, context: Context) {
        controller.onTap = onTap
        controller.onTurn = onTurn
        controller.view.backgroundColor = theme.backgroundColor
        controller.view.isAccessibilityElement = true
        controller.view.accessibilityTraits = .staticText
        controller.view.accessibilityLabel = accessibilityLabel()
        layout.apply(textColor: theme.foregroundColor)
        let plan = layout
        let currentFlow = flow
        let background = theme.backgroundColor
        let margin = horizontalMargin
        let drawn = onPageDrawn
        controller.configure = { page in
            page.layout = plan
            page.flow = currentFlow
            page.horizontalMargin = margin
            page.backgroundColor = background
            page.onPageDrawn = drawn
        }
        controller.apply(style: transition, index: pageIndex, pageCount: layout.pages.count)
    }

    private func accessibilityLabel() -> String {
        guard layout.pages.indices.contains(pageIndex) else { return "正文" }
        return "正文，第 \(pageIndex + 1) 页，共 \(layout.pages.count) 页"
    }
}
