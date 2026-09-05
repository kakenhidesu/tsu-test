// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Browser-derived request state retained only inside one encrypted source/origin partition.
public struct VerifiedBrowserSession: Hashable, Sendable {
    public static let maximumCookieBytes = 512 * 1024
    public static let maximumUserAgentBytes = 4 * 1024

    public let requestCookies: String
    public let userAgent: String

    public init(requestCookies: String, userAgent: String) throws {
        guard requestCookies.contains(where: { !$0.isWhitespace }),
              requestCookies.utf8.count <= Self.maximumCookieBytes else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        guard userAgent.contains(where: { !$0.isWhitespace }),
              !userAgent.contains("\r"), !userAgent.contains("\n"),
              userAgent.utf8.count <= Self.maximumUserAgentBytes else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        self.requestCookies = requestCookies
        self.userAgent = userAgent
    }
}

public struct VerifiedBrowserSessionSnapshot: Hashable, Sendable {
    public let session: VerifiedBrowserSession
    public let cachePartitionId: String
}

public actor VerifiedBrowserSessionStore {
    private let credentials: SourceCredentialStore
    private static let magic: UInt32 = 0x5453_4253
    private static let version: UInt32 = 1

    public init(credentials: SourceCredentialStore) {
        self.credentials = credentials
    }

    public func put(_ partition: SourceCredentialPartition, session: VerifiedBrowserSession) async throws {
        try await credentials.put(partition, plaintext: encode(session))
    }

    public func snapshot(_ partition: SourceCredentialPartition) async throws -> VerifiedBrowserSessionSnapshot? {
        guard let encrypted = try await credentials.snapshot(partition) else { return nil }
        guard let session = decode(encrypted.plaintext) else {
            try await credentials.delete(partition)
            return nil
        }
        return VerifiedBrowserSessionSnapshot(session: session, cachePartitionId: encrypted.cachePartitionId)
    }

    @discardableResult
    public func delete(_ partition: SourceCredentialPartition) async throws -> Bool {
        try await credentials.delete(partition)
    }

    private func encode(_ session: VerifiedBrowserSession) -> Data {
        var writer = BinaryWriter()
        writer.write(Self.magic)
        writer.write(Self.version)
        writer.write(text: session.requestCookies)
        writer.write(text: session.userAgent)
        return writer.data
    }

    private func decode(_ bytes: Data) -> VerifiedBrowserSession? {
        var reader = BinaryReader(bytes)
        do {
            guard try reader.readUInt32() == Self.magic, try reader.readUInt32() == Self.version else { return nil }
            let cookies = try reader.readText(maximum: VerifiedBrowserSession.maximumCookieBytes)
            let userAgent = try reader.readText(maximum: VerifiedBrowserSession.maximumUserAgentBytes)
            try reader.requireExhausted()
            return try VerifiedBrowserSession(requestCookies: cookies, userAgent: userAgent)
        } catch {
            return nil
        }
    }
}
