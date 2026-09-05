// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

/// One row of the installed-source list. Sign-in state is derived from a stored credential
/// partition, never from a network probe: opening this screen must not talk to any site.
public struct BrowseSourceRow: Identifiable, Sendable {
    public let source: InstalledSource
    public let isSignedIn: Bool
    public let isAvailable: Bool

    public var id: String { source.sourceId.value }
}

@MainActor
public final class BrowseModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<[BrowseSourceRow]> = .loading

    private let registry: SourceRegistry
    private let credentials: SourceCredentialStore
    private let remoteLibrary: RemoteLibraryStore

    public init(
        registry: SourceRegistry,
        credentials: SourceCredentialStore,
        remoteLibrary: RemoteLibraryStore
    ) {
        self.registry = registry
        self.credentials = credentials
        self.remoteLibrary = remoteLibrary
    }

    public func load() async {
        state = .loading
        do {
            let sources = try await registry.installedSources()
            guard !sources.isEmpty else {
                state = .empty(
                    title: "还没有安装来源",
                    detail: "从扩展市场添加一个仓库，或导入一个 .hxp 包。"
                )
                return
            }
            var rows: [BrowseSourceRow] = []
            for source in sources {
                rows.append(
                    BrowseSourceRow(
                        source: source,
                        isSignedIn: await isSignedIn(source),
                        isAvailable: try await remoteLibrary
                            .sourceAvailability(source.sourceId.value)?.available ?? true
                    )
                )
            }
            state = .content(rows)
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取已安装的来源。")
        }
    }

    /// A source with a stored credential for any of its declared web-login origins is signed in.
    private func isSignedIn(_ source: InstalledSource) async -> Bool {
        for origin in source.webLoginOrigins {
            guard let partition = try? SourceCredentialPartition(
                sourceId: source.sourceId.value,
                origin: origin
            ) else { continue }
            if let stored = try? await credentials.get(partition), stored != nil { return true }
        }
        return false
    }
}
