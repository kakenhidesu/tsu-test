// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

/// Every network test runs against this transport; no test may reach a real site.
actor RecordingTransport: HostHttpTransport {
    private var recorded: [HostHttpRequest] = []
    private let responder: @Sendable (HostHttpRequest) throws -> HostHttpResponse

    init(responder: @escaping @Sendable (HostHttpRequest) throws -> HostHttpResponse = RecordingTransport.ok) {
        self.responder = responder
    }

    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        recorded.append(request)
        return try responder(request)
    }

    func requests() -> [HostHttpRequest] { recorded }

    static let ok: @Sendable (HostHttpRequest) throws -> HostHttpResponse = { request in
        HostHttpResponse(
            status: 200,
            finalUrl: request.url,
            headers: ["content-type": "text/html; charset=utf-8", "set-cookie": "hidden"],
            bytes: Data("fixture".utf8)
        )
    }
}

enum NetworkFixture {
    static func origin(_ value: String) throws -> HttpsOrigin { try HttpsOrigin(value) }

    static func addPolicy() throws -> RemoteOperationRequestPolicy {
        try RemoteOperationRequestPolicy(
            origin: try origin("https://www.wenku8.net"),
            method: .post,
            path: "/remote/shelf",
            fixedParameters: ["mode": "add"],
            remoteBookIdParameter: "bid"
        )
    }

    static func grant(
        extensionVersion: String = "0.1.0",
        origins: Set<HttpsOrigin>? = nil,
        cookieMode: SourceCookieMode = .sourceScoped,
        cookieOrigins: Set<HttpsOrigin>? = nil,
        maximumResponseBytes: Int = 1_024,
        remoteAddPolicy: RemoteOperationRequestPolicy? = nil
    ) throws -> SourceNetworkGrant {
        let defaultOrigin = try origin("https://www.wenku8.net")
        return try SourceNetworkGrant(
            sourceId: "org.tsuyomi.wenku8",
            extensionVersion: extensionVersion,
            origins: origins ?? [defaultOrigin],
            cookieMode: cookieMode,
            cookieOrigins: cookieOrigins ?? (cookieMode == .none ? [] : [defaultOrigin]),
            maximumConcurrentRequests: 2,
            requestTimeoutMs: 15_000,
            maximumResponseBytes: maximumResponseBytes,
            remoteAddPolicy: remoteAddPolicy ?? (try addPolicy())
        )
    }

    static func request(
        url: String = "https://www.wenku8.net/book/1234.htm",
        headers: [String: String] = [:],
        decode: DecodeMode = .utf8,
        cache: NetworkCacheMode = .networkOnly,
        semanticCacheKey: String? = nil
    ) throws -> SourceNetworkRequest {
        try SourceNetworkRequest(
            url: url,
            method: .get,
            headers: headers,
            decode: decode,
            cache: cache,
            semanticCacheKey: semanticCacheKey
        )
    }

    static func addRequest(form: [String: String] = ["mode": "add", "bid": "42"]) throws -> SourceNetworkRequest {
        try SourceNetworkRequest(
            url: "https://www.wenku8.net/remote/shelf",
            method: .post,
            form: form,
            decode: .utf8,
            cache: .networkOnly
        )
    }
}

func assertHostFailure(
    _ expected: HostNetworkError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ action: () async throws -> Void
) async {
    do {
        try await action()
        XCTFail("Expected \(expected.rawValue)", file: file, line: line)
    } catch let failure as HostNetworkException {
        XCTAssertEqual(failure.error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected HostNetworkException, got \(error)", file: file, line: line)
    }
}

/// In-memory AEAD so credential partitioning is testable without a Keychain-backed key.
struct InMemoryAead: AeadPort {
    func encrypt(plaintext: Data, additionalAuthenticatedData: Data) throws -> AeadCiphertext {
        var iv = Data()
        for _ in 0..<gcmIvBytes { iv.append(UInt8.random(in: 0...255)) }
        var sealed = Data(Sha256.digest(iv + additionalAuthenticatedData))
        sealed.append(plaintext)
        return AeadCiphertext(iv: iv, ciphertext: sealed)
    }

    func decrypt(_ value: AeadCiphertext, additionalAuthenticatedData: Data) throws -> Data {
        guard value.ciphertext.count >= 32 else { throw CredentialStorageError.corruptOrUnauthenticated }
        let expected = Data(Sha256.digest(value.iv + additionalAuthenticatedData))
        guard value.ciphertext.prefix(32) == expected else {
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        return Data(value.ciphertext.dropFirst(32))
    }
}
