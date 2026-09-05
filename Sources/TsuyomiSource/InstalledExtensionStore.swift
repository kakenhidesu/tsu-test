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
}

/// Stores only the active verified archive for each source. Replacements are atomic in `QuotaFileStore`.
public struct InstalledExtensionStore: Sendable {
    private let files: QuotaFileStore

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func writeActive(_ verified: VerifiedHxpPackage) async throws {
        do {
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
}
