// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import XCTest
@testable import TsuyomiReader

final class ReaderEngineTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func document(blockCount: Int = 3, revision: String = "r1") throws -> ReaderDocument {
        let blocks = try (0..<blockCount).map { index in
            ReaderBlock.paragraph(try ReaderBlock.Paragraph(blockId: "b\(index)", text: "段落\(index)"))
        }
        return try ReaderDocument(
            kind: .chapter,
            identity: try DocumentIdentity(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "1234",
                contentId: "10001"
            ),
            title: "第一章",
            revision: revision,
            contentDigest: ReaderDocument.contentDigest(of: blocks),
            blocks: blocks
        )
    }

    private func epochs(
        _ document: ReaderDocument,
        layout: String = "w=390",
        layoutEpoch: Int64 = 1,
        navigationEpoch: Int64 = 1
    ) throws -> ReaderEpochs {
        try ReaderEpochs(
            document: document.identity,
            documentRevision: document.revision,
            contentDigest: document.contentDigest,
            documentEpoch: 1,
            sessionEpoch: 1,
            layoutKey: try LayoutKey(layout),
            layoutEpoch: layoutEpoch,
            navigationEpoch: navigationEpoch
        )
    }

    private func snapshot(
        _ document: ReaderDocument,
        _ epochs: ReaderEpochs,
        precision: LocatorPrecision,
        ownerId: Int64 = 1,
        targetId: String = "paged"
    ) throws -> SettledPositionSnapshot {
        var locator: ReaderLocator?
        switch precision {
        case .exact:
            locator = try ReaderLocator(
                document: document.identity,
                blockId: "b1",
                textAnchorDigest: ReaderDocumentSession.anchorDigest(document.blocks[1]),
                characterOffset: 2,
                chapterProgress: 0.5,
                capturedAt: capturedAt
            )
        case .degraded:
            locator = try ReaderLocator(
                document: document.identity,
                blockId: "b1",
                chapterProgress: 0.5,
                capturedAt: capturedAt
            )
        case .unavailable:
            locator = nil
        }
        return try SettledPositionSnapshot(
            locator: locator,
            precision: precision,
            document: document.identity,
            documentRevision: document.revision,
            contentDigest: document.contentDigest,
            documentEpoch: epochs.documentEpoch,
            sessionEpoch: epochs.sessionEpoch,
            layoutKey: epochs.layoutKey,
            layoutRevision: epochs.layoutEpoch,
            navigationEpoch: epochs.navigationEpoch,
            visualCommitWitness: try VisualCommitWitness(
                ownerId: ownerId,
                visualEpoch: 1,
                targetId: targetId,
                epochs: epochs
            )
        )
    }

    func testExactLocatorResolvesExactlyAndDegradesWhenTheAnchorIsMissing() throws {
        let document = try document()
        let exact = try ReaderLocator(
            document: document.identity,
            blockId: "b2",
            textAnchorDigest: ReaderDocumentSession.anchorDigest(document.blocks[2]),
            characterOffset: 1,
            capturedAt: capturedAt
        )
        let session = try ReaderDocumentSession(
            document: document,
            initialLocator: exact,
            initialPresentation: .paged
        )
        XCTAssertEqual(session.position.blockIndex, 2)
        XCTAssertEqual(session.position.characterOffset, 1)
        XCTAssertEqual(session.position.precision, .exact)

        let missingBlock = try ReaderLocator(
            document: document.identity,
            blockId: "absent",
            chapterProgress: 1.0,
            capturedAt: capturedAt
        )
        let fallback = try ReaderDocumentSession(
            document: document,
            initialLocator: missingBlock,
            initialPresentation: .paged
        )
        XCTAssertEqual(fallback.position.blockIndex, 2)
        XCTAssertEqual(fallback.position.precision, .degraded)
    }

    func testANearbyMatchingAnchorRecoversAReorderedBlock() throws {
        let document = try document()
        let anchorOnly = try ReaderLocator(
            document: document.identity,
            blockId: "renamed",
            textAnchorDigest: ReaderDocumentSession.anchorDigest(document.blocks[1]),
            capturedAt: capturedAt
        )
        let session = try ReaderDocumentSession(
            document: document,
            initialLocator: anchorOnly,
            initialPresentation: .scroll
        )
        XCTAssertEqual(session.position.blockIndex, 1)
        XCTAssertEqual(session.position.precision, .degraded)
    }

    func testEveryPresentationSharesOneLocator() throws {
        let document = try document()
        let session = try ReaderDocumentSession(
            document: document,
            initialLocator: nil,
            initialPresentation: .scroll
        )
        try session.navigateToBlock(1, characterOffset: 2)
        let before = session.position.locator
        session.switchPresentation(.paged)
        XCTAssertEqual(session.position.locator, before)
        session.switchPresentation(.dualPage)
        XCTAssertEqual(session.position.locator, before)
        XCTAssertEqual(session.presentation, .dualPage)
    }

    func testCaptureKeepsTheSemanticPositionAndOnlyMovesTheClock() throws {
        let session = try ReaderDocumentSession(
            document: try document(),
            initialLocator: nil,
            initialPresentation: .paged
        )
        try session.navigateToBlock(2)
        let later = Date(timeIntervalSince1970: 1_700_000_500)
        let captured = try session.capture(at: later)
        XCTAssertEqual(captured.blockId, session.position.locator.blockId)
        XCTAssertEqual(captured.characterOffset, session.position.locator.characterOffset)
        XCTAssertEqual(captured.capturedAt, later)
    }

    func testDegradedCaptureNeverDisplacesAnExactOne() throws {
        let document = try document()
        let epochs = try epochs(document)
        let cache = SettledPositionCache()
        XCTAssertEqual(cache.record(try snapshot(document, epochs, precision: .exact)), .accepted)
        XCTAssertEqual(
            cache.record(try snapshot(document, epochs, precision: .degraded)),
            .rejectedByExactPrecedence
        )
        XCTAssertEqual(cache.current()?.precision, .exact)
    }

    func testASnapshotRequiresAWitnessForItsOwnProvenance() throws {
        let document = try document()
        let epochs = try epochs(document)
        let foreign = try VisualCommitWitness(
            ownerId: 1,
            visualEpoch: 1,
            targetId: "paged",
            epochs: try self.epochs(document, layout: "w=1024", layoutEpoch: 9)
        )
        XCTAssertThrowsError(
            try SettledPositionSnapshot(
                locator: nil,
                precision: .unavailable,
                document: document.identity,
                documentRevision: document.revision,
                contentDigest: document.contentDigest,
                documentEpoch: epochs.documentEpoch,
                sessionEpoch: epochs.sessionEpoch,
                layoutKey: epochs.layoutKey,
                layoutRevision: epochs.layoutEpoch,
                navigationEpoch: epochs.navigationEpoch,
                visualCommitWitness: foreign
            )
        ) { XCTAssertEqual($0 as? ReaderEngineError, .witnessProvenanceMismatch) }
    }

    func testPresentationSwitchCommitsOnlyItsOwnCurrentWitness() throws {
        let document = try document()
        let source = try epochs(document)
        let target = try epochs(document, layout: "w=1024", layoutEpoch: 2)
        let cache = SettledPositionCache()
        cache.record(try snapshot(document, source, precision: .exact))

        guard case .started(let transaction) = PresentationSwitchTransaction.begin(
            PresentationSwitchRequest(
                transactionId: 7,
                targetId: "dual",
                sourceEpochs: source,
                targetEpochs: target,
                captures: cache,
                mountedCapture: cache.current(),
                mountedRendererIsRebuilding: false
            )
        ) else { return XCTFail("expected the switch to start") }

        let foreign = try VisualCommitWitness(ownerId: 8, visualEpoch: 1, targetId: "dual", epochs: target)
        XCTAssertEqual(
            transaction.acceptVisualCommit(foreign, currentTargetEpochs: target),
            .rejected(.staleOrForeignWitness)
        )
        XCTAssertTrue(transaction.isActive)

        let owned = try VisualCommitWitness(ownerId: 7, visualEpoch: 2, targetId: "dual", epochs: target)
        guard case .accepted = transaction.acceptVisualCommit(owned, currentTargetEpochs: target) else {
            return XCTFail("expected the owning witness to commit")
        }
        XCTAssertEqual(transaction.state, .committed)
        XCTAssertEqual(
            transaction.acceptVisualCommit(owned, currentTargetEpochs: target),
            .rejected(.alreadyCommitted)
        )
    }

    func testPresentationSwitchRejectsIncompatibleDocumentsAndMissingCaptures() throws {
        let document = try document()
        let source = try epochs(document)
        let other = try epochs(try document(revision: "r2"))
        let empty = SettledPositionCache()

        guard case .rejected(let incompatible) = PresentationSwitchTransaction.begin(
            PresentationSwitchRequest(
                transactionId: 1,
                targetId: "paged",
                sourceEpochs: source,
                targetEpochs: other,
                captures: empty,
                mountedCapture: nil,
                mountedRendererIsRebuilding: false
            )
        ) else { return XCTFail("expected a rejection") }
        XCTAssertEqual(incompatible, .incompatibleDocument)

        guard case .rejected(let missing) = PresentationSwitchTransaction.begin(
            PresentationSwitchRequest(
                transactionId: 1,
                targetId: "paged",
                sourceEpochs: source,
                targetEpochs: source,
                captures: empty,
                mountedCapture: nil,
                mountedRendererIsRebuilding: false
            )
        ) else { return XCTFail("expected a rejection") }
        XCTAssertEqual(missing, .noExactSettledCapture)
    }

    func testStaleTargetEpochsCancelAnOpenSwitch() throws {
        let document = try document()
        let source = try epochs(document)
        let cache = SettledPositionCache()
        cache.record(try snapshot(document, source, precision: .exact))
        guard case .started(let transaction) = PresentationSwitchTransaction.begin(
            PresentationSwitchRequest(
                transactionId: 3,
                targetId: "scroll",
                sourceEpochs: source,
                targetEpochs: source,
                captures: cache,
                mountedCapture: cache.current(),
                mountedRendererIsRebuilding: false
            )
        ) else { return XCTFail("expected the switch to start") }

        let reflowed = try epochs(document, layout: "w=1024", layoutEpoch: 5)
        XCTAssertTrue(transaction.invalidateIfStale(reflowed))
        XCTAssertEqual(transaction.state, .cancelled)
        XCTAssertEqual(
            transaction.acceptVisualCommit(
                try VisualCommitWitness(ownerId: 3, visualEpoch: 1, targetId: "scroll", epochs: source),
                currentTargetEpochs: source
            ),
            .rejected(.cancelled)
        )
    }

    func testDocumentCacheEvictsLeastRecentlyUsed() throws {
        let cache = ReaderDocumentCache(capacity: 2)
        let first = try document(revision: "r1")
        let second = try ReaderDocument(
            kind: .chapter,
            identity: try DocumentIdentity(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "1234",
                contentId: "10002"
            ),
            title: "第二章",
            revision: "r1",
            contentDigest: first.contentDigest,
            blocks: first.blocks
        )
        let third = try ReaderDocument(
            kind: .chapter,
            identity: try DocumentIdentity(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "1234",
                contentId: "10003"
            ),
            title: "第三章",
            revision: "r1",
            contentDigest: first.contentDigest,
            blocks: first.blocks
        )
        cache.put(first)
        cache.put(second)
        XCTAssertNotNil(cache.get(first.identity))
        cache.put(third)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.get(second.identity))
        XCTAssertNotNil(cache.get(first.identity))
        XCTAssertNotNil(cache.get(third.identity))
    }
}
