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

/// A local archive whose publisher nobody here trusts yet. The key id is a label read off the
/// manifest, not a verdict; the bytes are kept only until the reader answers or gives up.
public struct PendingPublisherKey: Sendable {
    public let keyId: String
    public let archiveBytes: Data
}

/// An install waiting for the reader's decision, together with the key that verified it when that
/// key came from the reader rather than from durable trust.
public struct PendingInstall: Sendable {
    public let prepared: PreparedExtensionInstall
    public let provisionalKey: PublisherKey?
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
    @Published public private(set) var pendingInstall: PendingInstall?
    @Published public private(set) var pendingPublisherKey: PendingPublisherKey?
    @Published public var installConsent = ExtensionInstallConsent()
    @Published public private(set) var failureCode: String?
    @Published public private(set) var importStatus: String?
    @Published public private(set) var isBusy = false

    private let registry: SourceRegistry
    private let repositories: RepositoryStore
    private let trust: PublisherTrustStore
    private let client: ExtensionRepositoryClient
    private let lifecycle: ExtensionLifecycle
    private let sourceRemoved: @MainActor (SourceId) async -> Void
    private let clock: () -> Date

    public init(
        registry: SourceRegistry,
        repositories: RepositoryStore,
        trust: PublisherTrustStore,
        client: ExtensionRepositoryClient,
        lifecycle: ExtensionLifecycle,
        sourceRemoved: @escaping @MainActor (SourceId) async -> Void,
        clock: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.repositories = repositories
        self.trust = trust
        self.client = client
        self.lifecycle = lifecycle
        self.sourceRemoved = sourceRemoved
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
                    detail: "仓库通过维护者公布的订阅链接添加：目录地址加上仓库标识与根公钥。添加一个仓库开始。"
                )
                return
            }
            state = .content(ExtensionsContent(installed: installed, repositories: added))
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取扩展状态。")
        }
    }

    /// Reads the catalog a subscription link the user pasted points at. Nothing is trusted until they
    /// confirm the root and publisher fingerprints the next screen shows.
    public func probeRepository(link: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let probed = try await client.probe(link: link)
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

    /// Removing a repository only stops it being offered. Installed extensions keep working, the
    /// publisher stays trusted until it is removed on its own screen, and the repository's identity
    /// and cached catalog are retained so the same id can only return under the same root. The
    /// official repository is disabled rather than removed: the app ships pointed at it.
    public func removeRepository(_ repositoryId: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if let descriptor = await repositories.descriptor(repositoryId), descriptor.isOfficial {
            try? await repositories.setEnabled(repositoryId, enabled: false)
        } else {
            try? await repositories.remove(repositoryId)
        }
        await load()
    }

    public func setRepositoryEnabled(_ repositoryId: String, enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        try? await repositories.setEnabled(repositoryId, enabled: enabled)
        await load()
    }

    /// The one way an archive arrives from a file, whether the in-app picker or Files handed it over.
    /// Both deliver a copy this app owns, so it is read once and deleted whatever the outcome, and
    /// each stage reports itself: an import that stops has to say where. A publisher nobody trusts
    /// yet stops at asking for that publisher's key; nothing is stored until the review is approved.
    public func importPackage(at url: URL) async {
        guard !isBusy else {
            failureCode = "BUSY"
            return
        }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        pendingPublisherKey = nil
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
            installConsent = ExtensionInstallConsent()
            pendingInstall = PendingInstall(prepared: prepared, provisionalKey: nil)
        } catch HxpVerificationError.unknownPublisher {
            guard let keyId = HxpArchiveVerifier.publisherKeyId(archiveBytes: bytes) else {
                importStatus = nil
                failureCode = HxpVerificationError.unknownPublisher.rawValue
                return
            }
            importStatus = "发布者 \(keyId) 尚未信任，需要它的公钥"
            pendingPublisherKey = PendingPublisherKey(keyId: keyId, archiveBytes: bytes)
        } catch {
            importStatus = nil
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// A key the reader typed verifies the waiting archive or it does not; either way it is not
    /// stored here. Verification proves who signed the package, not that it may run — that is the
    /// separate consent on the review that follows.
    public func providePublisherKey(_ base64: String) async {
        guard let pending = pendingPublisherKey, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let key = try PublisherKey(
                keyId: pending.keyId,
                publicKey: try ExtensionRepositoryClient.rootKey(base64),
                trust: .userAdded
            )
            let prepared = try await lifecycle.prepare(archiveBytes: pending.archiveBytes, provisionalKey: key)
            pendingPublisherKey = nil
            importStatus = "发布者公钥校验通过，等待安装审批"
            installConsent = ExtensionInstallConsent()
            pendingInstall = PendingInstall(prepared: prepared, provisionalKey: key)
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    public func discardPublisherKeyRequest() {
        pendingPublisherKey = nil
        importStatus = nil
    }

    /// The approval is consumed either way: a failed activation returns to the extension list with a
    /// stable code rather than leaving a sheet open over a result nobody can read.
    public func approvePendingInstall() async {
        guard let pending = pendingInstall, !isBusy else { return }
        isBusy = true
        defer {
            pendingInstall = nil
            importStatus = nil
            isBusy = false
        }
        do {
            try await lifecycle.activate(pending.prepared, consent: installConsent, retaining: pending.provisionalKey)
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
            await sourceRemoved(sourceId)
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
