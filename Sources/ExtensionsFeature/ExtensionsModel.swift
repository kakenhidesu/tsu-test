// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public struct PendingRepositoryApproval: Sendable {
    public let descriptor: RepositoryDescriptor
    public let index: RepositoryIndex
    public let isNewPublisherKey: Bool
}

public struct ExtensionsContent: Sendable {
    public let installed: [InstalledSource]
    public let repositories: [RepositoryDescriptor]
}

/// The market's home. It never refreshes on its own: every index read here happens because the
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
                    detail: "仓库是一个 HTTPS 基址，里面静态托管着签名索引与扩展包。添加一个仓库开始。"
                )
                return
            }
            state = .content(ExtensionsContent(installed: installed, repositories: added))
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取扩展状态。")
        }
    }

    /// Reads an index the user typed a base for. Nothing is trusted until they confirm the publisher
    /// fingerprint the next screen shows.
    public func probeRepository(base: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let probed = try await client.probe(base: base)
            let known = trust.resolve(keyId: probed.index.publisher.keyId)
            pendingApproval = PendingRepositoryApproval(
                descriptor: probed.descriptor,
                index: probed.index,
                isNewPublisherKey: known?.publicKey != probed.index.publisher.publicKey
            )
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    public func discardApproval() {
        pendingApproval = nil
    }

    /// The one place a publisher becomes trusted. It records the exact key the user was shown.
    public func approvePendingRepository() async {
        guard let pending = pendingApproval, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await trust.approve(
                TrustedPublisher(
                    keyId: pending.index.publisher.keyId,
                    publicKey: pending.index.publisher.publicKey,
                    trust: .userAdded,
                    repositoryId: pending.descriptor.repositoryId,
                    approvedAt: clock()
                )
            )
            try await repositories.add(pending.descriptor)
            try await lifecycle.applyRevocations(pending.index.revocations, now: clock())
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
        failureCode = nil
        importStatus = "已选择 \(url.lastPathComponent)"
        defer {
            importStatus = nil
            isBusy = false
        }
        let bytes = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard let bytes else {
            failureCode = "UNREADABLE_FILE"
            return
        }
        importStatus = "已读取 \(bytes.count) 字节，正在校验"
        do {
            pendingInstall = try await lifecycle.prepare(archiveBytes: bytes, declaring: nil)
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
            await load()
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    public func discardPendingInstall() {
        pendingInstall = nil
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
            try await lifecycle.applyRevocations([], now: clock())
            await load()
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }
}
