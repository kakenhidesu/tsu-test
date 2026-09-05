// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// One installed source as the interface sees it: identity, display data, and the capabilities that
/// decide which actions are even offered.
public struct InstalledSource: Hashable, Sendable {
    public let sourceId: SourceId
    public let version: SemanticVersion
    public let displayName: String
    public let summary: String
    public let publisherFingerprint: String
    public let packageSha256: String
    public let networkOrigins: Set<HttpsOrigin>
    public let supportsHome: Bool
    public let supportsWebLogin: Bool
    public let supportsRemoteRead: Bool
    public let supportsRemoteAdd: Bool
    public let webLoginOrigins: Set<HttpsOrigin>
}

/// Owns exactly one live runtime lane per installed source version. Opening a second client for the
/// same source would give an extension two contexts and two concurrent request budgets, so the
/// registry hands out the one it already has.
public actor SourceRegistry {
    private let installer: ExtensionInstaller
    private let store: InstalledExtensionStore
    private let gateway: HostNetworkGateway
    private var clients: [String: SourceExtensionClient] = [:]

    public init(installer: ExtensionInstaller, store: InstalledExtensionStore, gateway: HostNetworkGateway) {
        self.installer = installer
        self.store = store
        self.gateway = gateway
    }

    public func installedSources() async throws -> [InstalledSource] {
        var result: [InstalledSource] = []
        for sourceId in await store.installedSourceIds() {
            guard let verified = try? await installer.readVerifiedActive(sourceId) else { continue }
            result.append(SourceRegistry.describe(verified))
        }
        return result
    }

    public func client(for sourceId: SourceId) async throws -> SourceExtensionClient {
        if let existing = clients[sourceId.value] { return existing }
        guard let verified = try await installer.readVerifiedActive(sourceId) else {
            throw ExtensionInstallError.installedPackageInvalid
        }
        let client = try await SourceExtensionClient.open(packageInfo: verified, gateway: gateway)
        clients[sourceId.value] = client
        return client
    }

    /// Closing is how a source becomes dormant: the lane is torn down, and the next request must
    /// re-read and re-verify the installed package.
    public func close(_ sourceId: SourceId) async {
        guard let client = clients.removeValue(forKey: sourceId.value) else { return }
        await client.close()
    }

    public func closeAll() async {
        for client in clients.values { await client.close() }
        clients.removeAll()
    }

    static func describe(_ verified: VerifiedHxpPackage) -> InstalledSource {
        let manifest = verified.manifest
        return InstalledSource(
            sourceId: manifest.sourceId,
            version: manifest.version,
            displayName: manifest.displayName,
            summary: manifest.summary,
            publisherFingerprint: verified.publisherFingerprint,
            packageSha256: verified.packageSha256,
            networkOrigins: manifest.capabilities.network.origins,
            supportsHome: manifest.capabilities.home.enabled,
            supportsWebLogin: manifest.capabilities.webLogin.enabled,
            supportsRemoteRead: manifest.capabilities.remoteLibrary.read,
            supportsRemoteAdd: manifest.capabilities.remoteLibrary.writeOperations.contains("add"),
            webLoginOrigins: manifest.capabilities.webLogin.origins
        )
    }
}
