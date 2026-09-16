// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public enum PackageStatus: Sendable, Equatable {
    case available
    case installed
    case updatable(from: String)
    case incompatible
    case revoked
}

public struct RepositoryPackageRow: Sendable, Identifiable {
    public let package: RepositoryPackage
    public let status: PackageStatus

    public var id: String { "\(package.id.value)\u{0}\(package.version.original)" }
}

public struct RepositoryDetailContent: Sendable {
    public let index: RepositoryIndex
    public let rows: [RepositoryPackageRow]
    /// Publishers the catalog lists whose key is not trusted under the same bytes. Their packages
    /// cannot be installed until the reader trusts them here, one key at a time.
    public let untrustedPublishers: [RepositoryPublisher]
}

/// One repository. It reads its cached catalog on open and only talks to the network when the reader
/// refreshes, so browsing the market never becomes background traffic.
@MainActor
public final class RepositoryDetailModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<RepositoryDetailContent> = .loading
    @Published public private(set) var failureCode: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var pendingInstall: PreparedExtensionInstall?

    public let descriptor: RepositoryDescriptor

    private let registry: SourceRegistry
    private let repositories: RepositoryStore
    private let trust: PublisherTrustStore
    private let client: ExtensionRepositoryClient
    private let lifecycle: ExtensionLifecycle
    private let hostApi: SemanticVersion
    private let clock: () -> Date

    public init(
        descriptor: RepositoryDescriptor,
        registry: SourceRegistry,
        repositories: RepositoryStore,
        trust: PublisherTrustStore,
        client: ExtensionRepositoryClient,
        lifecycle: ExtensionLifecycle,
        hostApi: SemanticVersion,
        clock: @escaping () -> Date = Date.init
    ) {
        self.descriptor = descriptor
        self.registry = registry
        self.repositories = repositories
        self.trust = trust
        self.client = client
        self.lifecycle = lifecycle
        self.hostApi = hostApi
        self.clock = clock
    }

    public func loadCached() async {
        guard let cached = await repositories.cached(descriptor.repositoryId) else {
            state = .empty(title: "还没有目录", detail: "点击刷新从仓库读取一次目录。")
            return
        }
        do {
            let index = try RepositoryIndexCodec.decode(cached, rootPublicKey: descriptor.rootPublicKey, now: clock())
            await publish(index)
        } catch {
            state = .empty(title: "缓存的目录已失效", detail: "刷新以重新读取。")
        }
    }

    /// A refreshed catalog replaces the cached one only if it is at least as new: the sequence is
    /// root-signed, so a mirror cannot serve an older catalog to hide a revocation or an update, and
    /// two different catalogs under one sequence are equivocation rather than a refresh.
    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let fetched = try await client.refresh(descriptor)
            if let cached = await repositories.cached(descriptor.repositoryId),
               let previous = RepositoryIndexCodec.sequence(of: cached) {
                if fetched.index.sequence < previous { throw RepositoryError.indexRollback }
                if fetched.index.sequence == previous,
                   RepositoryIndexCodec.signedDigest(of: cached) != RepositoryIndexCodec.signedDigest(of: fetched.bytes) {
                    throw RepositoryError.indexEquivocation
                }
            }
            try await repositories.cache(descriptor.repositoryId, indexBytes: fetched.bytes)
            try await lifecycle.applyRevocations(fetched.index.revocations)
            await publish(fetched.index)
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// Trusting a listed publisher is the same act as approving a repository, made one key at a time
    /// for keys the catalog added after the repository was approved.
    public func trustPublisher(_ publisher: RepositoryPublisher) async {
        guard !isBusy, case .content(let content) = state else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            try await trust.approve(
                TrustedPublisher(
                    keyId: publisher.keyId,
                    publicKey: publisher.publicKey,
                    trust: .userAdded,
                    repositoryId: descriptor.repositoryId,
                    approvedAt: clock()
                )
            )
            await publish(content.index)
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// Downloads, verifies and prepares. Nothing is activated here: the review screen is the only
    /// place an install is approved.
    public func prepare(_ package: RepositoryPackage) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let archive = try await client.download(package)
            pendingInstall = try await lifecycle.prepare(archiveBytes: archive, declaring: package)
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// The approval is consumed either way: a failed activation returns to the package list with a
    /// stable code rather than leaving a sheet open over a result nobody can read.
    public func approvePendingInstall() async {
        guard let prepared = pendingInstall, !isBusy else { return }
        isBusy = true
        defer {
            pendingInstall = nil
            isBusy = false
        }
        do {
            try await lifecycle.activate(prepared)
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
        await loadCached()
    }

    /// Refusing an install leaves the previously active version running, which is the whole point of
    /// asking before a capability grows.
    public func discardPendingInstall() {
        pendingInstall = nil
    }

    private func publish(_ index: RepositoryIndex) async {
        let installed = (try? await registry.installedSources()) ?? []
        let versions = Dictionary(
            installed.map { ($0.sourceId.value, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = index.packages.map { package in
            RepositoryPackageRow(package: package, status: status(package, installed: versions[package.id.value]))
        }
        let untrusted = index.publishers.filter { trust.resolve(keyId: $0.keyId)?.publicKey != $0.publicKey }
        state = .content(RepositoryDetailContent(index: index, rows: rows, untrustedPublishers: untrusted))
    }

    private func status(_ package: RepositoryPackage, installed: SemanticVersion?) -> PackageStatus {
        if trust.isRevokedPackage(package.sha256) { return .revoked }
        guard package.acceptsHostApi(hostApi) else { return .incompatible }
        guard let installed else { return .available }
        if package.version > installed { return .updatable(from: installed.original) }
        return .installed
    }
}
