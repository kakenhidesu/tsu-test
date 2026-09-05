// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Immutable grant derived from the active signed manifest and the user's accepted review.
public struct SourceNetworkGrant: Hashable, Sendable {
    public let sourceId: String
    public let extensionVersion: String
    public let origins: Set<HttpsOrigin>
    public let cookieMode: SourceCookieMode
    public let cookieOrigins: Set<HttpsOrigin>
    public let maximumConcurrentRequests: Int
    public let requestTimeoutMs: Int
    public let maximumResponseBytes: Int
    public let remoteAddPolicy: RemoteOperationRequestPolicy?

    public init(
        sourceId: String,
        extensionVersion: String,
        origins: Set<HttpsOrigin>,
        cookieMode: SourceCookieMode,
        cookieOrigins: Set<HttpsOrigin>,
        maximumConcurrentRequests: Int,
        requestTimeoutMs: Int,
        maximumResponseBytes: Int,
        remoteAddPolicy: RemoteOperationRequestPolicy? = nil
    ) throws {
        guard sourceId.contains(where: { !$0.isWhitespace }),
              extensionVersion.contains(where: { !$0.isWhitespace }),
              !origins.isEmpty,
              (1...8).contains(maximumConcurrentRequests),
              (1_000...120_000).contains(requestTimeoutMs),
              (1_024...16_777_216).contains(maximumResponseBytes),
              cookieMode != .none || cookieOrigins.isEmpty,
              cookieOrigins.allSatisfy({ origins.contains($0) }) else {
            throw HostNetworkException(.invalidRequest)
        }
        if let remoteAddPolicy {
            guard remoteAddPolicy.remoteBookIdParameter != nil,
                  remoteAddPolicy.cursorParameter == nil,
                  origins.contains(remoteAddPolicy.origin) else {
                throw HostNetworkException(.invalidRequest)
            }
        }
        self.sourceId = sourceId
        self.extensionVersion = extensionVersion
        self.origins = origins
        self.cookieMode = cookieMode
        self.cookieOrigins = cookieOrigins
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.requestTimeoutMs = requestTimeoutMs
        self.maximumResponseBytes = maximumResponseBytes
        self.remoteAddPolicy = remoteAddPolicy
    }

    public func allowsCookies(_ origin: HttpsOrigin) -> Bool {
        cookieMode == .sourceScoped && cookieOrigins.contains(origin)
    }
}

public struct HostHttpRequest: Hashable, Sendable {
    public let url: URL
    public let method: NetworkMethod
    public let headers: [String: String]
    public let decode: DecodeMode
    public let body: Data?
    public let referrer: URL?
    public let timeoutMs: Int
    public let maximumResponseBytes: Int
}

public struct HostHttpResponse: Hashable, Sendable {
    public let status: Int
    public let finalUrl: URL
    public let headers: [String: String]
    public let bytes: Data

    public init(status: Int, finalUrl: URL, headers: [String: String], bytes: Data) {
        self.status = status
        self.finalUrl = finalUrl
        self.headers = headers
        self.bytes = bytes
    }
}

/// Opaque image response for host-owned media display; never exposed to extension code.
public struct HostMediaResponse: Hashable, Sendable {
    public let bytes: Data
    public let contentType: String
}

/// Host-only transport. It never exposes an HTTP response, cookies, or streams to extension code.
public protocol HostHttpTransport: Sendable {
    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse
}

public enum HostNetworkError: String, Sendable, Equatable, CaseIterable {
    case invalidRequest = "INVALID_REQUEST"
    case disallowedOrigin = "DISALLOWED_ORIGIN"
    case headerDisallowed = "HEADER_DISALLOWED"
    case bodyLimit = "BODY_LIMIT"
    case responseLimit = "RESPONSE_LIMIT"
    case offline = "OFFLINE"
    case timeout = "TIMEOUT"
    case cancelled = "CANCELLED"
    case redirectLimit = "REDIRECT_LIMIT"
    case redirectDisallowed = "REDIRECT_DISALLOWED"
    case offlineMiss = "OFFLINE_MISS"
    case decode = "DECODE"
    case transport = "TRANSPORT"
}

public struct HostNetworkException: Error, Hashable, Sendable {
    public let error: HostNetworkError
    public let diagnosticId: String

    public init(_ error: HostNetworkError, diagnosticId: String = UUID().uuidString) {
        self.error = error
        self.diagnosticId = diagnosticId
    }
}
