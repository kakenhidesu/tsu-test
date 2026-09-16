// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiRemoteLibrary
import TsuyomiSource
import TsuyomiUI

/// Where the destination menu's website section stands.
public enum RemoteDestinationsPhase: Equatable, Sendable {
    case idle
    case loading
    case unavailable
    case loaded
}

/// A message the book page shows after a website write, with the one follow-up it can offer.
public enum RemoteShelfBanner: Equatable, Sendable {
    case result(RemoteWriteOperation, RemoteMutationResult)
    case added(targetName: String?)
    case partialMove(targetId: String, targetName: String?, code: String)
    case unresolved(RemoteWriteOperation)
}

public struct RemoteShelfState: Equatable, Sendable {
    public let membership: RemoteMirrorItem?
    public let targets: [RemoteMirrorTarget]
    public let destinations: RemoteDestinationsPhase
    public let reconciliation: RemoteReconciliationRecord?
    public let supportedWrites: Set<RemoteWriteOperation>
    public let supportsTargets: Bool
    public let grouped: Bool

    public var inMirror: Bool { membership != nil }
    public var canAdd: Bool { supportedWrites.contains(.add) }
    public var canRemove: Bool { inMirror && supportedWrites.contains(.remove) }
    public var canMove: Bool { inMirror && grouped && supportedWrites.contains(.move) }
    public var liveTargets: [RemoteMirrorTarget] { targets.filter { !$0.frozen } }
    public var currentTargetId: String? {
        membership.map { RemoteMirrorTargets.resolvedTargetId($0, targets: targets) } ?? nil
    }
    public var hasUnresolved: Bool { reconciliation?.state == .unresolved }
    /// A targeted add that confirmed but whose move never did: the record names a folder the book
    /// is not in.
    public var pendingContinuation: (targetId: String, targetName: String?)? {
        guard let record = reconciliation, record.operation == .add, record.state == .confirmed,
              let targetId = record.targetId, inMirror, currentTargetId != targetId else { return nil }
        return (targetId, record.targetName)
    }
}

/// The book page's dealings with the site's own shelf. Local writes stay in `BookModel`; this model
/// owns the website section of the destination menu, the two overflow writes, and the record of
/// what the site said last time.
@MainActor
public final class BookRemoteShelfModel: ObservableObject {
    @Published public private(set) var state: RemoteShelfState?
    @Published public private(set) var banner: RemoteShelfBanner?
    @Published public private(set) var pendingAuthorization: RemoteWriteOperation?
    @Published public private(set) var isConfirmingRemoval = false
    @Published public private(set) var isBusy = false

    public let identity: BookIdentity
    private let coordinator: RemoteLibraryCoordinator
    private let mirror: RemoteMirrorStore
    private let remoteLibrary: RemoteLibraryStore
    private let preferences: AppPreferences
    private var deferred: (@MainActor () async -> Void)?

    public init(
        identity: BookIdentity,
        coordinator: RemoteLibraryCoordinator,
        mirror: RemoteMirrorStore,
        remoteLibrary: RemoteLibraryStore,
        preferences: AppPreferences
    ) {
        self.identity = identity
        self.coordinator = coordinator
        self.mirror = mirror
        self.remoteLibrary = remoteLibrary
        self.preferences = preferences
    }

    /// Reads what is stored; the site is not asked.
    public func load() async {
        guard let sourceId = try? SourceId(identity.sourceId) else { return }
        let stored = try? await mirror.mirror(sourceId: sourceId.value)
        let targets = stored?.targets ?? []
        state = RemoteShelfState(
            membership: try? await mirror.membership(identity),
            targets: targets,
            destinations: state?.destinations == .loading ? .loading : (targets.isEmpty ? .idle : .loaded),
            reconciliation: try? await remoteLibrary.latestReconciliation(identity),
            supportedWrites: await coordinator.supportedWrites(sourceId: sourceId),
            supportsTargets: await coordinator.supportsTargets(sourceId: sourceId),
            grouped: preferences.library.websiteGrouping(sourceId.value)
        )
    }

    /// Opening the destination menu is the one moment the folder list may be fetched, and only when
    /// nothing is stored yet. A source without folder discovery shows the single aggregate entry.
    public func openDestinations() async {
        guard let current = state, let sourceId = try? SourceId(identity.sourceId) else { return }
        guard current.supportsTargets, current.targets.isEmpty, current.destinations != .loading else { return }
        state = replacing(current, destinations: .loading)
        let result = await coordinator.refreshTargets(sourceId)
        await load()
        if case .confirmed = result, let loaded = state, !loaded.targets.isEmpty {
            state = replacing(loaded, destinations: .loaded)
        } else if let loaded = state {
            state = replacing(loaded, destinations: .unavailable)
        }
    }

    // MARK: Writes

    public func addToWebsite(_ detail: SourceBookDetail, targetId: String?, targetName: String?, at now: Date = Date()) async {
        let book = LibraryBook(
            identity: detail.summary.identity,
            title: detail.summary.title,
            addedAt: now,
            metadataUpdatedAt: now,
            authors: detail.summary.author.map { [$0] } ?? [],
            coverUrl: detail.summary.coverUrl,
            canonicalUrl: detail.summary.canonicalUrl,
            status: detail.status,
            remoteTags: Set(detail.tags)
        )
        await run(.add) { [coordinator] in
            let result = await coordinator.add(book, targetId: targetId, targetName: targetName)
            switch result {
            case .confirmed(let confirmedTargetId):
                return .added(targetName: targetName ?? (confirmedTargetId == nil ? nil : targetName))
            case .partial(_, let requestedTargetId, let requestedName, let code):
                return .partialMove(targetId: requestedTargetId, targetName: requestedName, code: code)
            case .unresolved:
                return .unresolved(.add)
            case .cancelled:
                return .result(.add, .cancelled)
            case .consentRequired(let operation):
                return .result(.add, .consentRequired(operation))
            case .loginRequired:
                return .result(.add, .loginRequired)
            case .verificationRequired:
                return .result(.add, .verificationRequired)
            case .failure(let failure, let code):
                return .result(.add, .failure(failure, code: code))
            }
        }
    }

    public func moveOnWebsite(targetId: String, targetName: String?) async {
        await run(.move) { [coordinator, identity] in
            let result = await coordinator.move(identity, targetId: targetId, targetName: targetName)
            if case .unresolved = result { return .unresolved(.move) }
            return .result(.move, result)
        }
    }

    /// Removal is confirmed on every use; the consent it needs is recorded once per source.
    public func requestRemoveFromWebsite() async {
        guard let sourceId = try? SourceId(identity.sourceId), !isBusy else { return }
        if await coordinator.writebackEnabled(.remove, sourceId: sourceId) {
            isConfirmingRemoval = true
        } else {
            pendingAuthorization = .remove
            deferred = { [weak self] in self?.isConfirmingRemoval = true }
        }
    }

    public func confirmRemoveFromWebsite() async {
        isConfirmingRemoval = false
        await run(.remove) { [coordinator, identity] in
            let result = await coordinator.remove(identity)
            if case .unresolved = result { return .unresolved(.remove) }
            return .result(.remove, result)
        }
    }

    public func cancelRemoveFromWebsite() {
        isConfirmingRemoval = false
    }

    public func retryUnresolved() async {
        guard let operation = state?.reconciliation?.operation else { return }
        await run(operation) { [coordinator, identity] in
            let result = await coordinator.retry(identity)
            if case .unresolved = result { return .unresolved(operation) }
            return .result(operation, result)
        }
    }

    /// `仅解除锁定`: lets the book be written again without claiming the site did anything.
    public func acknowledgeUnresolved() async {
        _ = await coordinator.acknowledgeUnresolved(identity)
        banner = nil
        await load()
    }

    public func authorizePendingOperation() async {
        guard let operation = pendingAuthorization, let sourceId = try? SourceId(identity.sourceId) else { return }
        pendingAuthorization = nil
        do {
            try await coordinator.grantWriteback(operation, sourceId: sourceId)
        } catch {
            banner = .result(operation, .failure(.sourceFailure, code: SafeErrorCode.of(error)))
            return
        }
        let next = deferred
        deferred = nil
        await next?()
    }

    public func cancelPendingOperation() {
        pendingAuthorization = nil
        deferred = nil
    }

    public func dismissBanner() {
        banner = nil
    }

    private func run(_ operation: RemoteWriteOperation, _ work: @escaping () async -> RemoteShelfBanner) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        banner = nil
        let outcome = await work()
        if case .result(_, .consentRequired(let needed)) = outcome {
            pendingAuthorization = needed
            deferred = { [weak self] in await self?.run(operation, work) }
            return
        }
        banner = outcome
        await load()
    }

    private func replacing(_ current: RemoteShelfState, destinations: RemoteDestinationsPhase) -> RemoteShelfState {
        RemoteShelfState(
            membership: current.membership,
            targets: current.targets,
            destinations: destinations,
            reconciliation: current.reconciliation,
            supportedWrites: current.supportedWrites,
            supportsTargets: current.supportsTargets,
            grouped: current.grouped
        )
    }
}
