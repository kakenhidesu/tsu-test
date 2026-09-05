// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Non-durable handoff from a settled source surface to a compatible target presentation. A snapshot
/// is intentionally invalid outside its exact provenance; it is never a progress record.
public struct SettledPositionSnapshot: Hashable, Sendable {
    public let locator: ReaderLocator?
    public let precision: LocatorPrecision
    public let document: DocumentIdentity
    public let documentRevision: String
    public let contentDigest: String
    public let documentEpoch: Int64
    public let sessionEpoch: Int64
    public let layoutKey: LayoutKey
    public let layoutRevision: Int64
    public let navigationEpoch: Int64
    public let visualCommitWitness: VisualCommitWitness

    public init(
        locator: ReaderLocator?,
        precision: LocatorPrecision,
        document: DocumentIdentity,
        documentRevision: String,
        contentDigest: String,
        documentEpoch: Int64,
        sessionEpoch: Int64,
        layoutKey: LayoutKey,
        layoutRevision: Int64,
        navigationEpoch: Int64,
        visualCommitWitness: VisualCommitWitness
    ) throws {
        guard !documentRevision.isEmpty else { throw ReaderEngineError.invalidDocumentRevision }
        guard document.revision == nil || document.revision == documentRevision else {
            throw ReaderEngineError.revisionDisagreesWithIdentity
        }
        guard layoutRevision >= 0 else { throw ReaderEngineError.negativeEpoch }
        let captured = try ReaderEpochs(
            document: document,
            documentRevision: documentRevision,
            contentDigest: contentDigest,
            documentEpoch: documentEpoch,
            sessionEpoch: sessionEpoch,
            layoutKey: layoutKey,
            layoutEpoch: layoutRevision,
            navigationEpoch: navigationEpoch
        )
        guard visualCommitWitness.epochs == captured else {
            throw ReaderEngineError.witnessProvenanceMismatch
        }
        switch precision {
        case .exact:
            guard let locator, locator.precision == .exact else {
                throw ReaderEngineError.exactSnapshotRequiresExactLocator
            }
        case .degraded:
            guard locator != nil else { throw ReaderEngineError.degradedSnapshotRequiresLocator }
        case .unavailable:
            guard locator == nil else { throw ReaderEngineError.unavailableSnapshotMustNotCarryLocator }
        }
        if let locator {
            guard locator.document.namesSameDocument(as: document) else {
                throw ReaderEngineError.locatorDocumentMismatch
            }
            guard locator.document.revision == nil || locator.document.revision == documentRevision else {
                throw ReaderEngineError.locatorRevisionMismatch
            }
        }
        self.locator = locator
        self.precision = precision
        self.document = document
        self.documentRevision = documentRevision
        self.contentDigest = contentDigest
        self.documentEpoch = documentEpoch
        self.sessionEpoch = sessionEpoch
        self.layoutKey = layoutKey
        self.layoutRevision = layoutRevision
        self.navigationEpoch = navigationEpoch
        self.visualCommitWitness = visualCommitWitness
    }

    public var epochs: ReaderEpochs { visualCommitWitness.epochs }

    public var isExactSettled: Bool { precision == .exact }

    public func isCompatible(with expected: ReaderEpochs) -> Bool { epochs == expected }
}

/// Outcome of admitting a capture into the in-memory settled-capture cache.
public enum CaptureAdmission: Sendable, Equatable {
    case accepted
    case rejectedByExactPrecedence
}

/// Keeps only the most recent settled capture. For one document and revision, a degraded or
/// unavailable observation never displaces a previously settled exact capture.
public final class SettledPositionCache {
    private var latest: SettledPositionSnapshot?

    public init() {}

    public func current() -> SettledPositionSnapshot? { latest }

    @discardableResult
    public func record(_ snapshot: SettledPositionSnapshot) -> CaptureAdmission {
        if let previous = latest,
           previous.document.namesSameDocument(as: snapshot.document),
           previous.documentRevision == snapshot.documentRevision,
           previous.contentDigest == snapshot.contentDigest,
           previous.documentEpoch == snapshot.documentEpoch,
           previous.sessionEpoch == snapshot.sessionEpoch,
           previous.navigationEpoch == snapshot.navigationEpoch,
           previous.isExactSettled,
           !snapshot.isExactSettled {
            return .rejectedByExactPrecedence
        }
        latest = snapshot
        return .accepted
    }

    /// Selects the only snapshot a presentation transaction may restore. The currently mounted exact
    /// capture always wins; a cache fallback is legal only while that mounted renderer is rebuilding.
    public func selectForPresentationSwitch(
        source: ReaderEpochs,
        mountedCapture: SettledPositionSnapshot?,
        mountedRendererIsRebuilding: Bool
    ) -> SettledPositionSnapshot? {
        if let mountedCapture, mountedCapture.isExactSettled, mountedCapture.isCompatible(with: source) {
            return mountedCapture
        }
        guard mountedRendererIsRebuilding else { return nil }
        guard let latest, latest.isExactSettled, latest.isCompatible(with: source) else { return nil }
        return latest
    }
}
