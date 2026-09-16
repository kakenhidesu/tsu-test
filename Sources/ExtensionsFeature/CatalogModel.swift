// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

/// Where the merged catalog stands. `stale` means nothing is usable now but something was once
/// verified and is still shown, marked as possibly out of date.
public enum CatalogStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable
    case failed(String)
}

/// One installable entry, from one repository. The id carries both so two repositories offering
/// the same package are two rows the reader can tell apart.
public struct CatalogItem: Identifiable, Sendable, Equatable {
    public let package: RepositoryPackage
    public let repositoryId: String
    public let repositoryName: String
    public let isOfficial: Bool
    public let status: PackageStatus
    /// False while the repository the item came from is disabled, expired or failed to read.
    public let isInstallable: Bool

    public var id: String { "\(repositoryId)\u{0}\(package.id.value)" }
}

/// The 可安装 list: every enabled repository's cached catalog, merged, with each package's state
/// against what is installed. It reads caches on open and talks to the network only on refresh.
@MainActor
public final class CatalogModel: ObservableObject {
    @Published public private(set) var items: [CatalogItem] = []
    @Published public private(set) var status: CatalogStatus = .idle
    @Published public private(set) var isStale = false
    @Published public private(set) var hasRepositories = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var pendingInstall: PreparedExtensionInstall?
    @Published public private(set) var preparing: String?
    @Published public private(set) var installFailure: (failure: InstallFailure, item: CatalogItem)?
    @Published public var installConsent = ExtensionInstallConsent()
    @Published public var query = ""

    private let registry: SourceRegistry
    private let repositories: RepositoryStore
    private let trust: PublisherTrustStore
    private let client: ExtensionRepositoryClient
    private let lifecycle: ExtensionLifecycle
    private let hostApi: SemanticVersion
    private let clock: () -> Date

    public init(
        registry: SourceRegistry,
        repositories: RepositoryStore,
        trust: PublisherTrustStore,
        client: ExtensionRepositoryClient,
        lifecycle: ExtensionLifecycle,
        hostApi: SemanticVersion,
        clock: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.repositories = repositories
        self.trust = trust
        self.client = client
        self.lifecycle = lifecycle
        self.hostApi = hostApi
        self.clock = clock
    }

    /// Local filter over name, summary, language, source id and repository name. No network.
    public var filtered: [CatalogItem] {
        let needle = query.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            [item.package.displayName, item.package.summary, item.package.language, item.package.id.value, item.repositoryName]
                .contains { $0.precomposedStringWithCompatibilityMapping.lowercased().contains(needle) }
        }
    }

    /// Reads every enabled repository's cache. An expired or undecodable cache still contributes
    /// its rows, marked not installable, so the reader sees what was once offered.
    public func loadCached() async {
        let descriptors = await repositories.all()
        hasRepositories = !descriptors.isEmpty
        var rows: [CatalogItem] = []
        var usable = 0
        var snapshots = 0
        for descriptor in descriptors where descriptor.enabled {
            guard let cached = await repositories.cached(descriptor.repositoryId) else { continue }
            snapshots += 1
            let decoded = try? RepositoryIndexCodec.decode(cached, rootPublicKey: descriptor.rootPublicKey, now: clock())
            if decoded != nil { usable += 1 }
            let index = decoded ?? RepositoryIndexCodec.decodeIgnoringExpiry(cached, rootPublicKey: descriptor.rootPublicKey)
            guard let index else { continue }
            rows += await items(index, descriptor: descriptor, installable: decoded != nil)
        }
        items = rows.sorted { lhs, rhs in
            if lhs.package.displayName != rhs.package.displayName {
                return CanonicalOrder.precedes(lhs.package.displayName, rhs.package.displayName)
            }
            return CanonicalOrder.precedes(lhs.id, rhs.id)
        }
        isStale = usable == 0 && snapshots > 0
        if status == .idle || status == .loading {
            status = usable > 0 ? .ready : (snapshots > 0 ? .unavailable : .idle)
        }
    }

    /// Refreshes every enabled repository in turn. One failing repository does not hide the others:
    /// its cached rows stay, not installable, and the status names the failure.
    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = .loading
        var firstFailure: String?
        for descriptor in await repositories.all() where descriptor.enabled {
            do {
                _ = try await RepositoryRefresh.perform(descriptor, client: client, repositories: repositories, lifecycle: lifecycle)
            } catch {
                firstFailure = firstFailure ?? SafeErrorCode.of(error)
            }
        }
        status = .idle
        await loadCached()
        if let firstFailure, items.isEmpty { status = .failed(firstFailure) }
    }

    public var installationAllowed: Bool {
        status == .ready && !isStale && !isBusy && preparing == nil
    }

    /// Downloads, verifies and prepares one item. Nothing is activated here.
    public func prepare(_ item: CatalogItem) async {
        guard installationAllowed, item.isInstallable else { return }
        preparing = item.id
        installFailure = nil
        defer { preparing = nil }
        do {
            let archive = try await client.download(item.package)
            installConsent = ExtensionInstallConsent()
            pendingInstall = try await lifecycle.prepare(archiveBytes: archive, declaring: item.package)
        } catch {
            installFailure = (InstallFailure.classify(error), item)
        }
    }

    public func retryFailedInstall() async {
        guard let failed = installFailure, failed.failure.kind == .download else { return }
        await prepare(failed.item)
    }

    public func dismissInstallFailure() {
        installFailure = nil
    }

    public func approvePendingInstall() async {
        guard let prepared = pendingInstall, !isBusy else { return }
        isBusy = true
        defer {
            pendingInstall = nil
            isBusy = false
        }
        do {
            try await lifecycle.activate(prepared, consent: installConsent)
        } catch {
            installFailure = nil
            status = .failed(SafeErrorCode.of(error))
        }
        await loadCached()
    }

    public func discardPendingInstall() {
        pendingInstall = nil
    }

    private func items(_ index: RepositoryIndex, descriptor: RepositoryDescriptor, installable: Bool) async -> [CatalogItem] {
        let installed = (try? await registry.installedSources()) ?? []
        let versions = Dictionary(installed.map { ($0.sourceId.value, $0.version) }, uniquingKeysWith: { first, _ in first })
        let trusted = Set(index.publishers.filter { trust.resolve(keyId: $0.keyId)?.publicKey == $0.publicKey }.map(\.keyId))
        return index.packages.map { package in
            CatalogItem(
                package: package,
                repositoryId: descriptor.repositoryId,
                repositoryName: descriptor.isOfficial ? "官方仓库" : descriptor.repositoryId,
                isOfficial: descriptor.isOfficial,
                status: status(package, installed: versions[package.id.value]),
                isInstallable: installable && trusted.contains(package.publisherKeyId)
            )
        }
    }

    private func status(_ package: RepositoryPackage, installed: SemanticVersion?) -> PackageStatus {
        if trust.isRevokedPackage(package.sha256) { return .revoked }
        guard package.acceptsHostApi(hostApi) else { return .incompatible }
        guard let installed else { return .available }
        if package.version > installed { return .updatable(from: installed.original) }
        return .installed
    }
}
