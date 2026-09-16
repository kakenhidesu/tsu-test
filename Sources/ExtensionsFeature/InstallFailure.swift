// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiSource

/// Why an install stopped, sorted by what the reader can do about it: a download can be retried as
/// is, a repository problem sends them back to the catalog, a verification failure means the bytes
/// are not the package, and storage is the device. Local imports can only be re-chosen.
public enum InstallFailureKind: String, Sendable {
    case download = "DOWNLOAD"
    case verification = "VERIFICATION"
    case repository = "REPOSITORY"
    case storage = "STORAGE"
    case install = "INSTALL"
    case fileAccess = "FILE_ACCESS"
}

public struct InstallFailure: Sendable, Equatable {
    public let kind: InstallFailureKind
    public let code: String

    public static func classify(_ error: any Error) -> InstallFailure {
        let code = SafeErrorCode.of(error)
        switch error {
        case let failure as HostNetworkException:
            switch failure.error {
            case .redirectDisallowed, .redirectLimit, .responseLimit:
                return InstallFailure(kind: .verification, code: code)
            default:
                return InstallFailure(kind: .download, code: code)
            }
        case let failure as RepositoryError:
            switch failure {
            case .indexExpired, .indexRollback, .indexEquivocation, .hostApiIncompatible, .downgradeRejected,
                 .repositoryIdentityMismatch, .unauthorizedMigration:
                return InstallFailure(kind: .repository, code: code)
            default:
                return InstallFailure(kind: .verification, code: code)
            }
        case let failure as HxpVerificationError:
            switch failure {
            case .revokedPublisher, .revokedPackage, .unknownPublisher:
                return InstallFailure(kind: .repository, code: code)
            default:
                return InstallFailure(kind: .verification, code: code)
            }
        case let failure as ExtensionInstallError:
            return InstallFailure(kind: failure == .storageUnavailable ? .storage : .install, code: code)
        case is StorageError:
            return InstallFailure(kind: .storage, code: code)
        default:
            return InstallFailure(kind: .install, code: code)
        }
    }
}
