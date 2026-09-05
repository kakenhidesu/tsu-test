// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// The only bridge from a thrown error to text an interface may display. Raw-value errors are
/// already stable codes; every other layer collapses to one code, so no message, URL, cookie or
/// stack fragment can reach the screen through an error path.
public enum SafeErrorCode {
    public static func of(_ error: any Error) -> String {
        switch error {
        case let failure as SourceException: return failure.code.rawValue
        case let failure as HxpVerificationError: return failure.rawValue
        case let failure as ExtensionInstallError: return failure.rawValue
        case let failure as QuickJsRuntimeError: return failure.rawValue
        case let failure as HostNetworkException: return failure.error.rawValue
        case is DatabaseError, is StorageError: return "STORAGE_FAILED"
        case is CredentialStorageError: return "CREDENTIAL_UNAVAILABLE"
        case is WebLoginSessionError: return "WEB_SESSION_FAILED"
        case is ProtocolError: return "CONTRACT_VIOLATION"
        default: return "UNEXPECTED_FAILURE"
        }
    }
}
