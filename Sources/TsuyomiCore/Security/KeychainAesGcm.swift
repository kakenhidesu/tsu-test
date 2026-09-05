// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Keychain-backed AES-256-GCM, the iOS form of ADR 0018. The master key is device-bound and never
/// synchronises; it is not held in the Secure Enclave because the enclave has no AES key type.
public struct KeychainAesGcm: AeadPort {
    private let alias: String

    public init(alias: String = sourceCredentialKeyAlias) {
        self.alias = alias
    }

    public func encrypt(plaintext: Data, additionalAuthenticatedData: Data) throws -> AeadCiphertext {
        let key = try masterKey()
        guard let sealed = try? AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(),
            authenticating: additionalAuthenticatedData
        ) else {
            throw CredentialStorageError.unavailable
        }
        return AeadCiphertext(iv: Data(sealed.nonce), ciphertext: sealed.ciphertext + sealed.tag)
    }

    public func decrypt(_ value: AeadCiphertext, additionalAuthenticatedData: Data) throws -> Data {
        guard value.iv.count == gcmIvBytes, value.ciphertext.count >= 16 else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        let key = try masterKey()
        guard let nonce = try? AES.GCM.Nonce(data: value.iv) else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        let body = value.ciphertext.prefix(value.ciphertext.count - 16)
        let tag = value.ciphertext.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag) else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        guard let plaintext = try? AES.GCM.open(box, using: key, authenticating: additionalAuthenticatedData) else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        return plaintext
    }

    private func masterKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let created = SymmetricKey(size: .bits256)
        try storeKey(created)
        // A concurrent process may have won the insert; the stored value is authoritative.
        guard let stored = try loadKey() else { throw CredentialStorageError.unavailable }
        return stored
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: alias,
            kSecAttrAccount as String: alias,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func loadKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw CredentialStorageError.unavailable
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStorageError.unavailable
        }
    }

    private func storeKey(_ key: SymmetricKey) throws {
        var query = baseQuery()
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CredentialStorageError.unavailable
        }
    }
}
