// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import os
import TsuyomiCore
import TsuyomiProtocol

/// One explicit consent to run one exact archive from a user-added publisher
/// (`hxp-package-v1` §Trust). A key the reader typed proves who signed a package; it does not say
/// the package may execute. That is this record, bound to the source, the publisher key and
/// fingerprint, and the complete archive digest, so it authorizes nothing else.
public struct PackageGrant: Hashable, Sendable {
    public let sourceId: String
    public let publisherKeyId: String
    public let publisherFingerprint: String
    public let packageSha256: String
    public let grantedAt: Date

    public init(sourceId: String, publisherKeyId: String, publisherFingerprint: String, packageSha256: String, grantedAt: Date) {
        self.sourceId = sourceId
        self.publisherKeyId = publisherKeyId
        self.publisherFingerprint = publisherFingerprint
        self.packageSha256 = packageSha256
        self.grantedAt = grantedAt
    }

    public static func covering(_ verified: VerifiedHxpPackage, at moment: Date) -> PackageGrant {
        PackageGrant(
            sourceId: verified.manifest.sourceId.value,
            publisherKeyId: verified.manifest.publisherKeyId,
            publisherFingerprint: verified.publisherFingerprint,
            packageSha256: verified.packageSha256,
            grantedAt: moment
        )
    }
}

/// Durable execution grants. Reads are synchronous because the installer checks them on the same
/// path that verifies an archive; only the file is touched asynchronously.
public final class PackageGrantStore: Sendable {
    private let files: QuotaFileStore
    private let path = "grants.json"
    private let state = OSAllocatedUnfairLock(initialState: [String: PackageGrant]())

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func load() async {
        guard let bytes = try? await files.read(path),
              let root = try? JSONValue.decode(bytes).objectValue else { return }
        var loaded: [String: PackageGrant] = [:]
        for row in root.array("grants") ?? [] {
            guard let object = row.objectValue,
                  let sourceId = object.string("sourceId"),
                  let keyId = object.string("publisherKeyId"),
                  let fingerprint = object.string("publisherFingerprint"),
                  let digest = object.string("packageSha256"),
                  let grantedAt = object.instant("grantedAt") else { continue }
            let grant = PackageGrant(
                sourceId: sourceId, publisherKeyId: keyId, publisherFingerprint: fingerprint,
                packageSha256: digest, grantedAt: grantedAt
            )
            loaded[PackageGrantStore.key(grant)] = grant
        }
        state.withLock { $0 = loaded }
    }

    public func record(_ grant: PackageGrant) async throws {
        state.withLock { $0[PackageGrantStore.key(grant)] = grant }
        try await persist()
    }

    /// A built-in publisher's package runs on its verification alone; a user-added publisher's
    /// package runs only under the grant that names exactly it.
    public func requireExecutable(_ verified: VerifiedHxpPackage) throws {
        guard verified.publisherTrust == .userAdded else { return }
        let key = PackageGrantStore.key(PackageGrant.covering(verified, at: Date(timeIntervalSince1970: 0)))
        guard state.withLock({ $0[key] != nil }) else { throw ExtensionInstallError.packageGrantRequired }
    }

    public var grants: [PackageGrant] {
        state.withLock { current in
            current.values.sorted { CanonicalOrder.precedes(PackageGrantStore.key($0), PackageGrantStore.key($1)) }
        }
    }

    private static func key(_ grant: PackageGrant) -> String {
        [grant.sourceId, grant.publisherKeyId, grant.publisherFingerprint, grant.packageSha256].joined(separator: "\u{0}")
    }

    private func persist() async throws {
        let rows = grants.map { grant in
            JSONValue.object([
                "sourceId": .string(grant.sourceId),
                "publisherKeyId": .string(grant.publisherKeyId),
                "publisherFingerprint": .string(grant.publisherFingerprint),
                "packageSha256": .string(grant.packageSha256),
                "grantedAt": .string(ProtocolTimestamp.format(grant.grantedAt))
            ])
        }
        _ = try await files.write(path, bytes: try Rfc8785.canonicalize(.object(["grants": .array(rows)])))
    }
}
