// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// A cover stream bound to exactly one source, package revision, and credential revision. A request
/// that does not match the bound partition is rejected rather than served from another partition's
/// cache, so a signed-out or re-signed session cannot see the previous session's images.
public struct CoverRepository: Sendable {
    private let sourceId: String
    private let packageRevision: String
    private let credentialRevision: String
    private let loader: HostCoverLoader

    public init(
        sourceId: String,
        packageRevision: String,
        credentialRevision: String,
        origins: Set<HttpsOrigin>,
        roots: StorageRoots,
        fetcher: any CoverMediaFetcher,
        maximumResponseBytes: Int = HostCoverLoader.defaultMaximumResponseBytes
    ) throws {
        self.sourceId = sourceId
        self.packageRevision = packageRevision
        self.credentialRevision = credentialRevision
        let partition = String(
            Sha256.hex("\(sourceId)\u{0}\(packageRevision)\u{0}\(credentialRevision)").prefix(24)
        )
        self.loader = HostCoverLoader(
            policy: try MediaOriginPolicy(origins: origins),
            files: try QuotaFileStore(
                roots: roots,
                root: .cache,
                namespace: "cover-\(partition)",
                quota: StorageQuota(maximumBytes: 64 * 1024 * 1024, maximumEntries: 4_096)
            ),
            fetcher: fetcher,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    public func observe(_ request: CoverRequest) -> AsyncStream<CoverUiState> {
        AsyncStream { continuation in
            let task = Task {
                guard request.sourceId == sourceId,
                      request.packageRevision == packageRevision,
                      request.credentialRevision == credentialRevision else {
                    continuation.yield(.failed(reason: .invalidReference, fallback: request.fallback))
                    continuation.finish()
                    return
                }
                continuation.yield(.loading(fallback: request.fallback))
                do {
                    let image = try await loader.load(
                        url: request.transportUrl,
                        referrerUrl: request.referrerUrl,
                        targetWidthPx: request.targetWidthPx,
                        targetHeightPx: request.targetHeightPx
                    )
                    continuation.yield(.ready(image))
                } catch let failure as MediaLoadError {
                    continuation.yield(.failed(reason: failure.publicReason, fallback: request.fallback))
                } catch {
                    continuation.yield(.failed(reason: .network, fallback: request.fallback))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
