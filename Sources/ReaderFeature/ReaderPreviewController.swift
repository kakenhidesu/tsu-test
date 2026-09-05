// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import TsuyomiReader

/// Drives one preview session for the progress slider. Dragging only changes what is drawn; the
/// single semantic navigation happens on release, and only against a page the reader actually saw.
@MainActor
public final class ReaderPreviewController {
    @Published public private(set) var previewPageIndex: Int?

    private var session: PreviewSession?
    private var sessionCounter: Int64 = -1
    private var visualEpoch: Int64 = 0
    private var planRevision: Int64 = 0
    private var pages: [String: Int] = [:]
    private var witness: PreviewVisualWitness?

    public init() {}

    public var isActive: Bool { session != nil }

    public func begin(epochs: ReaderEpochs, locators: [Int: ReaderLocator]) throws {
        sessionCounter += 1
        planRevision += 1
        var targets: [PreviewTarget] = []
        pages = [:]
        for (page, locator) in locators.sorted(by: { $0.key < $1.key }) {
            let target = try PreviewTarget(id: ReaderPreviewController.id(page), locator: locator)
            targets.append(target)
            pages[target.id] = page
        }
        witness = nil
        previewPageIndex = nil
        session = try PreviewSession(
            sessionId: sessionCounter,
            epochs: epochs,
            plan: FrozenPreviewPlan(revision: planRevision, targets: targets)
        )
    }

    public func offer(pageIndex: Int) throws {
        guard let session else { return }
        guard let target = session.plan.targets.first(where: { $0.id == ReaderPreviewController.id(pageIndex) })
        else { return }
        if case .ready = try session.requestTarget(target) {
            witness = nil
            previewPageIndex = pageIndex
        }
    }

    /// Called from the drawing surface. Only a painted page can produce a witness.
    public func pageDrawn(_ index: Int, epochs: ReaderEpochs) throws {
        guard let session, let request = session.currentRequest,
              pages[request.target.id] == index else { return }
        visualEpoch += 1
        witness = try PreviewVisualWitness(
            sessionId: session.sessionId,
            target: request.target,
            epochs: epochs,
            planRevision: session.plan.revision,
            requestGeneration: request.generation,
            visualEpoch: visualEpoch
        )
    }

    /// The one place a preview turns into a navigation. A rejected release moves nothing.
    public func release(epochs: ReaderEpochs) -> Int? {
        defer { finish() }
        guard let session else { return nil }
        guard case .committed(let target) = session.release(
            witness: witness,
            currentEpochs: epochs,
            currentPlanRevision: session.plan.revision
        ) else { return nil }
        return pages[target.id]
    }

    public func cancel() {
        session?.cancelForUserInteraction()
        finish()
    }

    private func finish() {
        session = nil
        witness = nil
        previewPageIndex = nil
        pages = [:]
    }

    private static func id(_ page: Int) -> String { "page-\(page)" }
}
