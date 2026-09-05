// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public enum ReaderEngineError: Error, Equatable, Sendable {
    case blankLayoutKey
    case invalidDocumentRevision
    case revisionDisagreesWithIdentity
    case invalidContentDigest
    case negativeEpoch
    case invalidWitness
    case witnessProvenanceMismatch
    case exactSnapshotRequiresExactLocator
    case degradedSnapshotRequiresLocator
    case unavailableSnapshotMustNotCarryLocator
    case locatorDocumentMismatch
    case locatorRevisionMismatch
}

/// Metric-affecting layout identity. A colour-only change must not create a new key, or every theme
/// switch would needlessly invalidate pagination.
public struct LayoutKey: Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard value.contains(where: { !$0.isWhitespace }) else { throw ReaderEngineError.blankLayoutKey }
        self.value = value
    }
}

/// Immutable provenance carried by all reader work and visual commits. Any changed member makes an
/// asynchronous result stale. The document revision is explicit even though a durable
/// `DocumentIdentity` may omit it for backward protocol compatibility.
public struct ReaderEpochs: Hashable, Sendable {
    public let document: DocumentIdentity
    public let documentRevision: String
    public let contentDigest: String
    public let documentEpoch: Int64
    public let sessionEpoch: Int64
    public let layoutKey: LayoutKey
    public let layoutEpoch: Int64
    public let navigationEpoch: Int64

    public init(
        document: DocumentIdentity,
        documentRevision: String,
        contentDigest: String,
        documentEpoch: Int64,
        sessionEpoch: Int64,
        layoutKey: LayoutKey,
        layoutEpoch: Int64,
        navigationEpoch: Int64
    ) throws {
        guard Grammar.hasCodePoints(documentRevision, in: 1...256) else {
            throw ReaderEngineError.invalidDocumentRevision
        }
        guard document.revision == nil || document.revision == documentRevision else {
            throw ReaderEngineError.revisionDisagreesWithIdentity
        }
        guard Grammar.isSha256(contentDigest) else { throw ReaderEngineError.invalidContentDigest }
        guard documentEpoch >= 0, sessionEpoch >= 0, layoutEpoch >= 0, navigationEpoch >= 0 else {
            throw ReaderEngineError.negativeEpoch
        }
        self.document = document
        self.documentRevision = documentRevision
        self.contentDigest = contentDigest
        self.documentEpoch = documentEpoch
        self.sessionEpoch = sessionEpoch
        self.layoutKey = layoutKey
        self.layoutEpoch = layoutEpoch
        self.navigationEpoch = navigationEpoch
    }

    /// Architecture terminology for `layoutEpoch`.
    public var layoutRevision: Int64 { layoutEpoch }

    public func withLayout(_ key: LayoutKey, epoch: Int64) throws -> ReaderEpochs {
        try ReaderEpochs(
            document: document,
            documentRevision: documentRevision,
            contentDigest: contentDigest,
            documentEpoch: documentEpoch,
            sessionEpoch: sessionEpoch,
            layoutKey: key,
            layoutEpoch: epoch,
            navigationEpoch: navigationEpoch
        )
    }
}

/// Evidence that a particular target was actually committed to a visual surface. A capture without
/// one is a guess about what the reader saw, and the engine never persists a guess.
public struct VisualCommitWitness: Hashable, Sendable {
    public let ownerId: Int64
    public let visualEpoch: Int64
    public let targetId: String
    public let epochs: ReaderEpochs

    public init(ownerId: Int64, visualEpoch: Int64, targetId: String, epochs: ReaderEpochs) throws {
        guard ownerId >= 0, visualEpoch >= 0, targetId.contains(where: { !$0.isWhitespace }) else {
            throw ReaderEngineError.invalidWitness
        }
        self.ownerId = ownerId
        self.visualEpoch = visualEpoch
        self.targetId = targetId
        self.epochs = epochs
    }
}
