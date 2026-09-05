// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public let sourceCredentialKeyAlias = "org.tsuyomi.ios.source-credentials.v1"
let credentialSchemaVersion: UInt16 = 1
let credentialKeyVersion: UInt16 = 1
let gcmIvBytes = 12

/// A source partition has no ambient or global credential namespace.
public struct SourceCredentialPartition: Hashable, Sendable {
    public let sourceId: String
    public let origin: HttpsOrigin

    public init(sourceId: String, origin: HttpsOrigin) throws {
        guard Grammar.isLegacySourceId(sourceId) else { throw ProtocolError.sourceIdGrammar }
        self.sourceId = sourceId
        self.origin = origin
    }

    /// ADR 0018: the additional authenticated data binds a record to the format version, the source
    /// identity, and the exact origin, so a record cannot be replayed into another partition.
    var additionalAuthenticatedData: Data {
        var writer = BinaryWriter()
        writer.write(text: "tsuyomi-source-credentials")
        writer.write(UInt32(credentialSchemaVersion))
        writer.write(UInt32(credentialKeyVersion))
        writer.write(text: sourceId)
        writer.write(text: origin.canonical)
        return writer.data
    }
}

public enum CredentialStorageError: Error, Equatable, Sendable {
    case unavailable
    case corruptOrUnauthenticated
    case deleteFailed
}

public struct AeadCiphertext: Hashable, Sendable {
    public let iv: Data
    public let ciphertext: Data

    public init(iv: Data, ciphertext: Data) {
        self.iv = iv
        self.ciphertext = ciphertext
    }
}

/// Narrow port so credential partitioning stays testable without a Keychain-backed key.
public protocol AeadPort: Sendable {
    func encrypt(plaintext: Data, additionalAuthenticatedData: Data) throws -> AeadCiphertext
    func decrypt(_ value: AeadCiphertext, additionalAuthenticatedData: Data) throws -> Data
}
