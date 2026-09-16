// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// The one path from a screen to a website's own shelf. Reading it refreshes the local mirror;
/// writing to it is a signed, single-use, user-initiated operation whose every attempt is on record
/// before the request leaves. Nothing here runs on its own: every call is a reader's act.
public actor RemoteLibraryCoordinator {
    public static let maximumRecords = 5_000
    public static let maximumPages = 100

    private let registry: SourceRegistry
    private let remoteLibrary: RemoteLibraryStore
    private let mirror: RemoteMirrorStore
    private let library: LibraryRepository
    private let sessions: VerifiedBrowserSessionStore
    private let tokens: DirectActionTokenRegistry
    private let clock: @Sendable () -> Date
    private var writing: Set<String> = []

    public init(
        registry: SourceRegistry,
        remoteLibrary: RemoteLibraryStore,
        mirror: RemoteMirrorStore,
        library: LibraryRepository,
        sessions: VerifiedBrowserSessionStore,
        tokens: DirectActionTokenRegistry,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.remoteLibrary = remoteLibrary
        self.mirror = mirror
        self.library = library
        self.sessions = sessions
        self.tokens = tokens
        self.clock = clock
    }

    // MARK: Policy and consent

    /// The policy row follows the package that verifies now. Calling this before any website
    /// operation is what retires a consent whose capability set has changed underneath it.
    public func synchronize(_ client: SourceExtensionClient) async throws {
        try await remoteLibrary.synchronizeVerifiedPackage(
            sourceId: client.manifest.sourceId.value,
            publisherFingerprint: client.packageInfo.publisherFingerprint,
            capabilityFingerprint: client.remoteCapabilitySetFingerprint,
            approvedOrigin: client.manifest.remoteApprovedOrigin,
            preserveWriteback: true
        )
    }

    /// The website writes this source's package declares, whatever the reader has consented to.
    public func supportedWrites(sourceId: SourceId) async -> Set<RemoteWriteOperation> {
        guard let client = try? await registry.client(for: sourceId) else { return [] }
        let policies = client.manifest.capabilities.remoteLibrary.policies
        return Set(RemoteWriteOperation.allCases.filter { policies[RemoteOperation($0)] != nil })
    }

    public func supportsTargets(sourceId: SourceId) async -> Bool {
        guard let client = try? await registry.client(for: sourceId) else { return false }
        return client.manifest.capabilities.remoteLibrary.policies[.targets] != nil
    }

    /// Whether this source may perform the operation for the reader right now, without asking.
    public func writebackEnabled(_ operation: RemoteWriteOperation, sourceId: SourceId) async -> Bool {
        guard let client = try? await registry.client(for: sourceId),
              client.manifest.capabilities.remoteLibrary.policies[RemoteOperation(operation)] != nil,
              (try? await synchronize(client)) != nil,
              let policy = try? await remoteLibrary.sourceRemotePolicy(sourceId.value) else { return false }
        return policy.writebackEnabled(operation)
    }

    /// Records the reader's consent for one operation under the capability set that verifies now.
    public func grantWriteback(_ operation: RemoteWriteOperation, sourceId: SourceId) async throws {
        let client = try await registry.client(for: sourceId)
        try await synchronize(client)
        try await remoteLibrary.setWritebackEnabled(
            operation,
            sourceId: sourceId.value,
            capabilityFingerprint: client.remoteCapabilitySetFingerprint,
            enabled: true
        )
    }

    public func firstImportPromptDismissed(sourceId: SourceId) async -> Bool {
        (try? await remoteLibrary.sourceRemotePolicy(sourceId.value))?.firstImportPromptDismissed ?? false
    }

    public func dismissFirstImportPrompt(sourceId: SourceId) async throws {
        let client = try await registry.client(for: sourceId)
        try await synchronize(client)
        try await remoteLibrary.dismissFirstRemoteImportPrompt(
            sourceId: sourceId.value,
            capabilityFingerprint: client.remoteCapabilitySetFingerprint
        )
    }

    // MARK: Reading the site's shelf

    /// Reads the whole shelf and, if the source lists folders, the folders, then replaces the mirror
    /// in one transaction. Bounds are enforced on this side: the site cannot make the read endless.
    public func pull(_ sourceId: SourceId) async -> RemoteLibraryPullResult {
        let client: SourceExtensionClient
        do {
            client = try await registry.client(for: sourceId)
        } catch {
            return .failure(.sourceUnavailable, code: SafeErrorCode.of(error))
        }
        guard client.manifest.capabilities.remoteLibrary.policies[.read] != nil else {
            return .failure(.readNotGranted, code: RemoteLibraryFailure.readNotGranted.rawValue)
        }
        guard let lease = await lease(client) else {
            return .failure(.sourceChanged, code: RemoteLibraryFailure.sourceChanged.rawValue)
        }
        var books: [LibraryBook] = []
        var memberships: [BookIdentity: String?] = [:]
        var seenCursors: Set<String> = []
        var cursor: String?
        var pages = 0
        let now = clock()
        do {
            while true {
                let page = try await client.listRemoteLibrary(cursor: cursor)
                pages += 1
                for item in page.items {
                    guard item.identity.sourceId == sourceId.value else {
                        return .failure(.sourceIdentityMismatch, code: RemoteLibraryFailure.sourceIdentityMismatch.rawValue)
                    }
                    guard memberships[item.identity] == nil else { continue }
                    memberships[item.identity] = .some(item.remoteTargetId)
                    books.append(RemoteLibraryCoordinator.book(item, at: now))
                }
                guard books.count <= RemoteLibraryCoordinator.maximumRecords else {
                    return .failure(.recordLimit, code: RemoteLibraryFailure.recordLimit.rawValue)
                }
                if page.complete {
                    guard page.nextCursor == nil else {
                        return .failure(.completeWithCursor, code: RemoteLibraryFailure.completeWithCursor.rawValue)
                    }
                    break
                }
                guard let next = page.nextCursor else { break }
                guard seenCursors.insert(next).inserted else {
                    return .failure(.duplicateCursor, code: RemoteLibraryFailure.duplicateCursor.rawValue)
                }
                guard pages < RemoteLibraryCoordinator.maximumPages else {
                    return .failure(.pageLimit, code: RemoteLibraryFailure.pageLimit.rawValue)
                }
                cursor = next
            }
            var targets: [RemoteMirrorTarget] = []
            if client.manifest.capabilities.remoteLibrary.policies[.targets] != nil {
                targets = RemoteMirrorTargets.targets(try await client.listRemoteTargets())
            }
            try await mirror.save(
                RemoteMirrorSnapshot(
                    sourceId: sourceId.value,
                    displayName: client.manifest.displayName,
                    targets: targets,
                    books: books,
                    memberships: memberships,
                    expectedVersion: lease.version,
                    expectedCapabilityFingerprint: lease.capabilityFingerprint,
                    expectedGeneration: lease.generation,
                    observedAt: now
                )
            )
            return .success(count: books.count)
        } catch let failure as SourceException {
            switch failure.code {
            case .sessionRequired: return .loginRequired
            case .verificationRequired: return .verificationRequired
            case .extensionCancelled: return .cancelled
            default: return .failure(.sourceFailure, code: SafeErrorCode.of(failure))
            }
        } catch {
            return .failure(.sourceFailure, code: SafeErrorCode.of(error))
        }
    }

    /// Refreshes only the folder list, for a destination menu opened before any full read.
    public func refreshTargets(_ sourceId: SourceId) async -> RemoteMutationResult {
        guard let client = try? await registry.client(for: sourceId) else {
            return .failure(.sourceUnavailable, code: RemoteLibraryFailure.sourceUnavailable.rawValue)
        }
        guard client.manifest.capabilities.remoteLibrary.policies[.targets] != nil else {
            return .failure(.targetsNotGranted, code: RemoteLibraryFailure.targetsNotGranted.rawValue)
        }
        do {
            let list = try await client.listRemoteTargets()
            try await mirror.ensureBinding(sourceId: sourceId.value, displayName: client.manifest.displayName, at: clock())
            try await mirror.replaceTargets(sourceId: sourceId.value, RemoteMirrorTargets.targets(list), at: clock())
            return .confirmed
        } catch {
            return mapped(error)
        }
    }

    // MARK: Writing to the site's shelf

    public func add(_ book: LibraryBook, targetId: String?, targetName: String?) async -> RemoteTargetedAddResult {
        guard let sourceId = try? SourceId(book.identity.sourceId) else {
            return .failure(.sourceUnavailable, code: RemoteLibraryFailure.sourceUnavailable.rawValue)
        }
        let stored = try? await mirror.mirror(sourceId: sourceId.value)
        let defaultTargetId = RemoteMirrorTargets.defaultTargetId(stored?.targets ?? [])
        let continuation = targetId.flatMap { $0 == defaultTargetId ? nil : $0 }
        let added = await perform(
            .add,
            book: book,
            targetId: continuation,
            targetName: continuation == nil ? nil : targetName,
            retrying: nil
        )
        guard case .confirmed = added else { return RemoteTargetedAddResult(added, targetId: nil) }
        guard let continuation else { return .confirmed(targetId: defaultTargetId) }
        let moved = await perform(.move, book: book, targetId: continuation, targetName: targetName, retrying: nil)
        switch moved {
        case .confirmed:
            return .confirmed(targetId: continuation)
        case .unresolved:
            return .partial(
                defaultTargetId: defaultTargetId, requestedTargetId: continuation,
                requestedName: targetName, code: "unresolved"
            )
        case .cancelled:
            return .partial(
                defaultTargetId: defaultTargetId, requestedTargetId: continuation,
                requestedName: targetName, code: "cancelled"
            )
        case .consentRequired:
            return .partial(
                defaultTargetId: defaultTargetId, requestedTargetId: continuation,
                requestedName: targetName, code: RemoteLibraryFailure.moveNotAuthorized.rawValue
            )
        case .loginRequired:
            return .partial(
                defaultTargetId: defaultTargetId, requestedTargetId: continuation,
                requestedName: targetName, code: "login-required"
            )
        case .verificationRequired:
            return .partial(
                defaultTargetId: defaultTargetId, requestedTargetId: continuation,
                requestedName: targetName, code: "verification-required"
            )
        case .failure(_, let code):
            return .partial(
                defaultTargetId: defaultTargetId, requestedTargetId: continuation,
                requestedName: targetName, code: code
            )
        }
    }

    public func remove(_ identity: BookIdentity) async -> RemoteMutationResult {
        guard let book = try? await library.book(identity), (try? await mirror.membership(identity)) != nil else {
            return .failure(.bookNotInMirror, code: RemoteLibraryFailure.bookNotInMirror.rawValue)
        }
        return await perform(.remove, book: book, targetId: nil, targetName: nil, retrying: nil)
    }

    public func move(_ identity: BookIdentity, targetId: String, targetName: String?) async -> RemoteMutationResult {
        guard let book = try? await library.book(identity), (try? await mirror.membership(identity)) != nil else {
            return .failure(.bookNotInMirror, code: RemoteLibraryFailure.bookNotInMirror.rawValue)
        }
        return await perform(.move, book: book, targetId: targetId, targetName: targetName, retrying: nil)
    }

    /// Repeats the operation the latest unresolved record stands for. A confirmed retry closes the
    /// whole unresolved chain: the site has now said what happened.
    public func retry(_ identity: BookIdentity) async -> RemoteMutationResult {
        guard let record = try? await remoteLibrary.latestReconciliation(identity) else {
            return .failure(.noReconciliationRecord, code: RemoteLibraryFailure.noReconciliationRecord.rawValue)
        }
        guard record.state == .unresolved else {
            return .failure(.reconciliationNotRetryable, code: RemoteLibraryFailure.reconciliationNotRetryable.rawValue)
        }
        guard let book = try? await library.book(identity) else {
            return .failure(.bookNotInMirror, code: RemoteLibraryFailure.bookNotInMirror.rawValue)
        }
        if record.operation == .move, record.targetId == nil {
            return .failure(.missingTargetId, code: RemoteLibraryFailure.missingTargetId.rawValue)
        }
        return await perform(
            record.operation, book: book, targetId: record.targetId, targetName: record.targetName, retrying: record
        )
    }

    /// Releases the lock an unresolved move or removal holds, without claiming an outcome. An add
    /// the site may already have applied cannot be declared undone from here.
    public func acknowledgeUnresolved(_ identity: BookIdentity) async -> Bool {
        guard let record = try? await remoteLibrary.latestReconciliation(identity),
              record.state == .unresolved, record.operation != .add else { return false }
        return (try? await remoteLibrary.transitionRemoteMutation(
            id: record.id, expected: .unresolved, next: .cancelled, now: clock()
        )) ?? false
    }

    // MARK: One attempt

    private struct Lease {
        let version: String
        let capabilityFingerprint: String
        let generation: Int64
        let openGeneration: Int64
    }

    private func lease(_ client: SourceExtensionClient) async -> Lease? {
        let sourceId = client.manifest.sourceId
        guard (try? await synchronize(client)) != nil,
              let availability = try? await remoteLibrary.sourceAvailability(sourceId.value),
              availability.available,
              availability.verifiedVersion == client.manifest.version.original else { return nil }
        return Lease(
            version: client.manifest.version.original,
            capabilityFingerprint: client.remoteCapabilitySetFingerprint,
            generation: availability.generation,
            openGeneration: await registry.openGeneration(sourceId)
        )
    }

    private func perform(
        _ operation: RemoteWriteOperation,
        book: LibraryBook,
        targetId: String?,
        targetName: String?,
        retrying: RemoteReconciliationRecord?
    ) async -> RemoteMutationResult {
        let identity = book.identity
        guard let sourceId = try? SourceId(identity.sourceId) else {
            return .failure(.sourceUnavailable, code: RemoteLibraryFailure.sourceUnavailable.rawValue)
        }
        guard writing.insert(sourceId.value).inserted else {
            return .failure(.blockedUnresolved, code: "remote-mutation-busy")
        }
        defer { writing.remove(sourceId.value) }
        guard let client = try? await registry.client(for: sourceId) else {
            return .failure(.sourceUnavailable, code: RemoteLibraryFailure.sourceUnavailable.rawValue)
        }
        guard let policy = client.manifest.capabilities.remoteLibrary.policies[RemoteOperation(operation)] else {
            return .failure(RemoteLibraryFailure.notAuthorized(operation), code: RemoteLibraryFailure.notAuthorized(operation).rawValue)
        }
        guard let lease = await lease(client) else {
            return .failure(.sourceChanged, code: RemoteLibraryFailure.sourceChanged.rawValue)
        }
        guard let receipt = try? await remoteLibrary.sourceRemotePolicy(sourceId.value) else {
            return .failure(.policyMissing, code: RemoteLibraryFailure.policyMissing.rawValue)
        }
        guard receipt.writebackEnabled(operation) else { return .consentRequired(operation) }
        guard await hasSession(sourceId: sourceId, origin: policy.origin) else { return .loginRequired }
        if operation == .move, targetId == nil {
            return .failure(.missingTargetId, code: RemoteLibraryFailure.missingTargetId.rawValue)
        }
        if let refusal = await coalescingRefusal(identity, operation: operation, retrying: retrying) {
            return .failure(refusal, code: refusal.rawValue)
        }
        let now = clock()
        let reconciliationId: String
        do {
            reconciliationId = try await remoteLibrary.beginRemoteMutation(
                RemoteMutationRequest(
                    book: book,
                    operation: operation,
                    targetId: targetId,
                    targetName: targetName,
                    packageDigest: client.packageInfo.packageSha256,
                    packageVersion: lease.version,
                    capabilitySetFingerprint: lease.capabilityFingerprint,
                    registryGeneration: lease.generation,
                    retryingUnresolvedId: retrying?.id,
                    startedAt: now
                )
            )
        } catch {
            return .failure(.blockedUnresolved, code: SafeErrorCode.of(error))
        }
        let binding = DirectActionBinding(
            sourceId: sourceId.value,
            remoteBookId: identity.remoteBookId,
            reconciliationId: reconciliationId,
            packageDigest: client.packageInfo.packageSha256,
            packageVersion: lease.version,
            capabilitySetFingerprint: lease.capabilityFingerprint,
            registryGeneration: lease.generation,
            ownerGeneration: lease.openGeneration
        )
        let token = await tokens.mint(binding) { [self] in
            await self.accept(binding, operation: operation)
        }
        do {
            switch operation {
            case .add:
                _ = try await client.addRemoteLibrary(remoteBookId: identity.remoteBookId, directActionToken: token)
            case .remove:
                _ = try await client.removeRemoteLibrary(remoteBookId: identity.remoteBookId, directActionToken: token)
            case .move:
                _ = try await client.moveRemoteLibrary(
                    remoteBookId: identity.remoteBookId, targetId: targetId ?? "", directActionToken: token
                )
            }
        } catch {
            return await settleFailed(reconciliationId, token: token, error: error)
        }
        return await confirm(reconciliationId, identity: identity, operation: operation, targetId: targetId, client: client)
    }

    /// The gateway calls this when the token is presented. The lease is checked again here, at the
    /// last moment before bytes leave, because the package or the lane may have changed since the
    /// attempt was opened.
    private func accept(_ binding: DirectActionBinding, operation: RemoteWriteOperation) async -> Bool {
        guard let sourceId = try? SourceId(binding.sourceId),
              (try? await remoteLibrary.leaseValid(
                  sourceId: binding.sourceId,
                  version: binding.packageVersion,
                  capabilityFingerprint: binding.capabilitySetFingerprint,
                  generation: binding.registryGeneration
              )) == true,
              await registry.openGeneration(sourceId) == binding.ownerGeneration,
              (try? await remoteLibrary.sourceRemotePolicy(binding.sourceId))?.writebackEnabled(operation) == true
        else { return false }
        return (try? await remoteLibrary.transitionRemoteMutation(
            id: binding.reconciliationId, expected: .pendingUserAction, next: .inFlight, now: clock()
        )) ?? false
    }

    private func confirm(
        _ reconciliationId: String,
        identity: BookIdentity,
        operation: RemoteWriteOperation,
        targetId: String?,
        client: SourceExtensionClient
    ) async -> RemoteMutationResult {
        let now = clock()
        do {
            try await remoteLibrary.transitionRemoteMutation(
                id: reconciliationId, expected: .inFlight, next: .confirmed, now: now
            )
            try await remoteLibrary.confirmUnresolvedMutations(identity, operation: operation, now: now)
            switch operation {
            case .add:
                try await mirror.ensureBinding(sourceId: identity.sourceId, displayName: client.manifest.displayName, at: now)
                let stored = try await mirror.mirror(sourceId: identity.sourceId)
                try await mirror.setMembership(
                    identity, targetId: RemoteMirrorTargets.defaultTargetId(stored?.targets ?? []), at: now
                )
            case .remove:
                try await mirror.removeMembership(identity)
            case .move:
                try await mirror.setMembership(identity, targetId: targetId, at: now)
            }
            return .confirmed
        } catch {
            return .failure(.sourceFailure, code: SafeErrorCode.of(error))
        }
    }

    /// A request that failed after the token was accepted may have reached the site: the record
    /// stays unresolved with the diagnostic. One that never got that far is simply cancelled.
    private func settleFailed(_ reconciliationId: String, token: String, error: any Error) async -> RemoteMutationResult {
        _ = await tokens.revoke(token)
        let now = clock()
        let record = try? await remoteLibrary.reconciliation(id: reconciliationId)
        switch record?.state {
        case .inFlight?:
            let diagnostic = (error as? SourceException)?.diagnostic.correlationId
            _ = try? await remoteLibrary.transitionRemoteMutation(
                id: reconciliationId, expected: .inFlight, next: .unresolved, now: now, diagnosticId: diagnostic
            )
            return .unresolved
        case .pendingUserAction?:
            _ = try? await remoteLibrary.transitionRemoteMutation(
                id: reconciliationId, expected: .pendingUserAction, next: .cancelled, now: now
            )
            return mapped(error)
        default:
            return mapped(error)
        }
    }

    private func mapped(_ error: any Error) -> RemoteMutationResult {
        if let failure = error as? SourceException {
            switch failure.code {
            case .sessionRequired: return .loginRequired
            case .verificationRequired: return .verificationRequired
            case .extensionCancelled: return .cancelled
            default: break
            }
        }
        if let host = error as? HostNetworkException, host.error == .cancelled { return .cancelled }
        return .failure(.sourceFailure, code: SafeErrorCode.of(error))
    }

    /// One attempt at a time per book. A blocking record refuses everything except the retry of that
    /// very record; a confirmed add refuses a second add outright.
    private func coalescingRefusal(
        _ identity: BookIdentity,
        operation: RemoteWriteOperation,
        retrying: RemoteReconciliationRecord?
    ) async -> RemoteLibraryFailure? {
        guard let latest = try? await remoteLibrary.latestReconciliation(identity) else { return nil }
        if let retrying {
            return latest.id == retrying.id && latest.state == .unresolved && latest.operation == operation
                ? nil : .reconciliationNotRetryable
        }
        switch latest.state {
        case .pendingUserAction, .inFlight, .unresolved:
            return .blockedUnresolved
        case .confirmed:
            return operation == .add && latest.operation == .add ? .bookAlreadyAdded : nil
        case .cancelled:
            return nil
        }
    }

    private func hasSession(sourceId: SourceId, origin: HttpsOrigin) async -> Bool {
        guard let partition = try? SourceCredentialPartition(sourceId: sourceId.value, origin: origin) else {
            return false
        }
        return ((try? await sessions.snapshot(partition)) ?? nil) != nil
    }

    private static func book(_ item: SourceBookSummary, at now: Date) -> LibraryBook {
        LibraryBook(
            identity: item.identity,
            title: item.title,
            addedAt: now,
            metadataUpdatedAt: now,
            authors: item.author.map { [$0] } ?? [],
            coverUrl: item.coverUrl,
            canonicalUrl: item.canonicalUrl
        )
    }
}

extension RemoteOperation {
    init(_ operation: RemoteWriteOperation) {
        switch operation {
        case .add: self = .add
        case .remove: self = .remove
        case .move: self = .move
        }
    }
}
