// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public struct PendingRepositoryApproval: Sendable {
    public let descriptor: RepositoryDescriptor
    public let fetched: FetchedRepositoryIndex
    /// Publishers the catalog lists that are not yet trusted under the same key bytes.
    public let newPublisherKeyIds: Set<String>

    public var index: RepositoryIndex { fetched.index }
}

public struct ExtensionsContent: Sendable {
    public let installed: [InstalledSource]
    public let repositories: [RepositoryDescriptor]
}

/// The market's home. It never refreshes on its own: every catalog read here happens because the
/// reader asked for it.
@MainActor
public final class ExtensionsModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<ExtensionsContent> = .loading
    @Published public private(set) var pendingApproval: PendingRepositoryApproval?
    @Published public private(set) var pendingInstall: PreparedExtensionInstall?
    @Published public private(set) var failureCode: String?
    @Published public private(set) var importStatus: String?
    @Published public private(set) var isBusy = false

    private let registry: SourceRegistry
    private let repositories: RepositoryStore
    private let trust: PublisherTrustStore
    private let client: ExtensionRepositoryClient
    private let lifecycle: ExtensionLifecycle
    private let clock: () -> Date

    public init(
        registry: SourceRegistry,
        repositories: RepositoryStore,
        trust: PublisherTrustStore,
        client: ExtensionRepositoryClient,
        lifecycle: ExtensionLifecycle,
        clock: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.repositories = repositories
        self.trust = trust
        self.client = client
        self.lifecycle = lifecycle
        self.clock = clock
    }

    public var trustedPublishers: [TrustedPublisher] { trust.trusted }

    public func load() async {
        do {
            let installed = try await registry.installedSources()
            let added = await repositories.all()
            guard !installed.isEmpty || !added.isEmpty else {
                state = .empty(
                    title: "还没有扩展来源",
                    detail: "仓库是一个 HTTPS 地址上的签名目录，由仓库维护者公布的根公钥签名。添加一个仓库开始。"
                )
                return
            }
            state = .content(ExtensionsContent(installed: installed, repositories: added))
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取扩展状态。")
        }
    }

    /// Reads a catalog the user typed an address and root key for. Nothing is trusted until they
    /// confirm the root and publisher fingerprints the next screen shows.
    public func probeRepository(indexUrl: String, rootPublicKey: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let probed = try await client.probe(indexUrl: indexUrl, rootPublicKey: rootPublicKey)
            pendingApproval = PendingRepositoryApproval(
                descriptor: probed.descriptor,
                fetched: probed.fetched,
                newPublisherKeyIds: newPublisherKeyIds(probed.fetched.index)
            )
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    public func discardApproval() {
        pendingApproval = nil
    }

    /// The one place a repository's publishers become trusted. It records the exact keys the user was
    /// shown; a key already trusted under the same bytes is left as it is.
    public func approvePendingRepository() async {
        guard let pending = pendingApproval, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for publisher in pending.index.publishers where pending.newPublisherKeyIds.contains(publisher.keyId) {
                try await trust.approve(
                    TrustedPublisher(
                        keyId: publisher.keyId,
                        publicKey: publisher.publicKey,
                        trust: .userAdded,
                        repositoryId: pending.descriptor.repositoryId,
                        approvedAt: clock()
                    )
                )
            }
            try await repositories.add(pending.descriptor)
            try await repositories.cache(pending.descriptor.repositoryId, indexBytes: pending.fetched.bytes)
            try await lifecycle.applyRevocations(pending.index.revocations)
            pendingApproval = nil
            await load()
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// Removing a repository drops its cache only. Installed extensions keep working and the
    /// publisher stays trusted until it is removed on its own screen.
    public func removeRepository(_ repositoryId: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        try? await repositories.remove(repositoryId)
        await load()
    }

    /// The one way an archive arrives from a file, whether the in-app picker or Files handed it over.
    /// Both deliver a copy this app owns, so it is read once and deleted whatever the outcome, and
    /// each stage reports itself: an import that stops has to say where. Verification and approval
    /// are the same as for a repository download; only the way the bytes arrived differs.
    public func importPackage(at url: URL) async {
        guard !isBusy else {
            failureCode = "BUSY"
            return
        }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        importStatus = "已选择 \(url.lastPathComponent)"
        let bytes = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard let bytes else {
            importStatus = nil
            failureCode = "UNREADABLE_FILE"
            return
        }
        importStatus = "已读取 \(bytes.count) 字节，正在校验"
        do {
            let prepared = try await lifecycle.prepare(archiveBytes: bytes, declaring: nil)
            importStatus = "校验通过，等待安装审批"
            pendingInstall = prepared
        } catch {
            importStatus = nil
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// The approval is consumed either way: a failed activation returns to the extension list with a
    /// stable code rather than leaving a sheet open over a result nobody can read.
    public func approvePendingInstall() async {
        guard let prepared = pendingInstall, !isBusy else { return }
        isBusy = true
        defer {
            pendingInstall = nil
            importStatus = nil
            isBusy = false
        }
        do {
            try await lifecycle.activate(prepared)
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
        await load()
    }

    public func discardPendingInstall() {
        pendingInstall = nil
        importStatus = nil
    }

    public func uninstall(_ sourceId: SourceId) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await lifecycle.uninstall(sourceId)
            await load()
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// Forgetting a publisher deactivates everything it signed: the packages no longer verify, so the
    /// next read closes them and marks their sources dormant.
    public func forgetPublisher(_ keyId: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await trust.forget(keyId: keyId)
            try await lifecycle.closeUnverifiable()
            await load()
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    private func newPublisherKeyIds(_ index: RepositoryIndex) -> Set<String> {
        Set(
            index.publishers
                .filter { trust.resolve(keyId: $0.keyId)?.publicKey != $0.publicKey }
                .map(\.keyId)
        )
    }
}
