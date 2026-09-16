// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

public enum ExtensionInstallError: String, Error, Equatable, Sendable, CaseIterable {
    case storageUnavailable = "STORAGE_UNAVAILABLE"
    case approvalMismatch = "APPROVAL_MISMATCH"
    case downgradeRequiresConfirmation = "DOWNGRADE_REQUIRES_CONFIRMATION"
    case replayRejected = "REPLAY_REJECTED"
    case keyRotationNotAuthorized = "KEY_ROTATION_NOT_AUTHORIZED"
    case capabilityGrantRequired = "CAPABILITY_GRANT_REQUIRED"
    case installedPackageInvalid = "INSTALLED_PACKAGE_INVALID"
    case packageGrantRequired = "PACKAGE_GRANT_REQUIRED"
    case migrationConsentRequired = "MIGRATION_CONSENT_REQUIRED"
    case busy = "EXTENSION_MUTATION_BUSY"
}

/// The publisher a source was last activated under, kept after the archive is gone so that a
/// missing archive cannot be used to slip a different publisher in for the same source
/// (`hxp-package-v1` §Trust).
public struct PublisherPin: Hashable, Sendable {
    public let publisherFingerprint: String
    public let packageSha256: String

    public init(publisherFingerprint: String, packageSha256: String) {
        self.publisherFingerprint = publisherFingerprint
        self.packageSha256 = packageSha256
    }
}

/// Stores the active verified archive for each source and the pin it was activated under.
/// Replacements are atomic in `QuotaFileStore`; removing an archive leaves its pin in place.
public struct InstalledExtensionStore: Sendable {
    private let files: QuotaFileStore

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func writeActive(_ verified: VerifiedHxpPackage) async throws {
        let pin = JSONValue.object([
            "publisherFingerprint": .string(verified.publisherFingerprint),
            "packageSha256": .string(verified.packageSha256)
        ])
        do {
            _ = try await files.write(InstalledExtensionStore.pinPath(verified.manifest.sourceId), bytes: try Rfc8785.canonicalize(pin))
            _ = try await files.write(InstalledExtensionStore.path(verified.manifest.sourceId), bytes: verified.archiveBytes)
        } catch {
            throw ExtensionInstallError.storageUnavailable
        }
    }

    public func readActive(_ sourceId: SourceId) async throws -> Data? {
        do {
            return try await files.read(InstalledExtensionStore.path(sourceId))
        } catch {
            throw ExtensionInstallError.storageUnavailable
        }
    }

    public func publisherPin(_ sourceId: SourceId) async -> PublisherPin? {
        guard let bytes = try? await files.read(InstalledExtensionStore.pinPath(sourceId)),
              let object = try? JSONValue.decode(bytes).objectValue,
              let fingerprint = object.string("publisherFingerprint"), Grammar.isSha256(fingerprint),
              let digest = object.string("packageSha256"), Grammar.isSha256(digest) else { return nil }
        return PublisherPin(publisherFingerprint: fingerprint, packageSha256: digest)
    }

    @discardableResult
    public func remove(_ sourceId: SourceId) async throws -> Bool {
        do {
            return try await files.delete(InstalledExtensionStore.path(sourceId))
        } catch {
            throw ExtensionInstallError.storageUnavailable
        }
    }

    public func installedSourceIds() async -> [SourceId] {
        await files.entries()
            .compactMap { stored -> SourceId? in
                guard stored.relativePath.hasPrefix("active/"), stored.relativePath.hasSuffix(".hxp") else {
                    return nil
                }
                let value = String(stored.relativePath.dropFirst("active/".count).dropLast(".hxp".count))
                return try? SourceId(value)
            }
            .sorted { CanonicalOrder.precedes($0.value, $1.value) }
    }

    private static func path(_ sourceId: SourceId) -> String { "active/\(sourceId.value).hxp" }

    private static func pinPath(_ sourceId: SourceId) -> String { "pins/\(sourceId.value).json" }
}
