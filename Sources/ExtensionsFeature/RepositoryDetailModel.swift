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
}

/// One repository. It reads its cached index on open and only talks to the network when the reader
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
            state = .empty(title: "还没有索引", detail: "点击刷新从仓库读取一次索引。")
            return
        }
        do {
            let index = try RepositoryIndexCodec.decode(
                indexBytes: cached.index,
                signature: cached.signature,
                now: clock(),
                expectedPublicKey: descriptor.publisherPublicKey
            )
            await publish(index)
        } catch {
            state = .empty(title: "缓存的索引已失效", detail: "刷新以重新读取。")
        }
    }

    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let index = try await client.refresh(descriptor)
            try await lifecycle.applyRevocations(index.revocations, now: clock())
            await publish(index)
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
            let archive = try await client.download(package, from: descriptor)
            pendingInstall = try await lifecycle.prepare(
                archiveBytes: archive,
                declaring: package
            )
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    public func approvePendingInstall() async {
        guard let prepared = pendingInstall, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await lifecycle.activate(prepared)
            pendingInstall = nil
            await loadCached()
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
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
        state = .content(RepositoryDetailContent(index: index, rows: rows))
    }

    private func status(_ package: RepositoryPackage, installed: SemanticVersion?) -> PackageStatus {
        if trust.isRevokedPackage(package.sha256) { return .revoked }
        guard package.acceptsHostApi(hostApi) else { return .incompatible }
        guard let installed else { return .available }
        if package.version > installed { return .updatable(from: installed.original) }
        return .installed
    }
}
