// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct SourceId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        guard Grammar.isStrictSourceId(value) else { throw ProtocolError.invalidSourceId }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { value }
}

public struct HttpsOrigin: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String
    public let canonical: String

    public init(_ value: String) throws {
        guard let components = URLComponents(string: value) else { throw ProtocolError.invalidHttpsOrigin }
        guard components.scheme?.lowercased() == "https" else { throw ProtocolError.originNotHttps }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ProtocolError.invalidHttpsOrigin
        }
        guard components.path.isEmpty || components.path == "/" else { throw ProtocolError.originContainsPath }
        guard let host = components.host, !host.isEmpty else { throw ProtocolError.originMissingHost }
        if let port = components.port, !(0...65_535).contains(port) { throw ProtocolError.invalidOriginPort }
        self.value = value
        let lowercasedHost = host.lowercased()
        if let port = components.port, port != 443 {
            self.canonical = "https://\(lowercasedHost):\(port)"
        } else {
            self.canonical = "https://\(lowercasedHost)"
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }

    public static func == (lhs: HttpsOrigin, rhs: HttpsOrigin) -> Bool { lhs.canonical == rhs.canonical }
    public func hash(into hasher: inout Hasher) { hasher.combine(canonical) }
    public var description: String { canonical }
}

public enum DecodeMode: String, Sendable, Codable, CaseIterable {
    case auto = "auto"
    case utf8 = "utf-8"
    case gb18030 = "gb18030"
    case big5hkscs = "big5-hkscs"
}

public enum NetworkMethod: String, Sendable, Codable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

public enum NetworkCacheMode: String, Sendable, Codable, CaseIterable {
    case `default` = "default"
    case networkOnly = "network-only"
    case validate = "validate"
    case offlineOnly = "offline-only"
}

public enum NetworkCacheState: String, Sendable, Codable, CaseIterable {
    case fresh = "fresh"
    case validated = "validated"
    case staleOffline = "stale-offline"
    case miss = "miss"
    case bypassed = "bypassed"
}

/// Cookie capability modes declared by a verified source manifest.
public enum SourceCookieMode: String, Sendable, Codable, CaseIterable {
    case none = "none"
    case sourceScoped = "sourceScoped"
}

public struct SourceNetworkRequest: Hashable, Sendable {
    public let url: String
    public let method: NetworkMethod
    public let headers: [String: String]
    public let form: [String: String]?
    public let utf8Body: String?
    public let decode: DecodeMode
    public let cache: NetworkCacheMode
    public let semanticCacheKey: String?
    public let referrerUrl: String?

    public init(
        url: String,
        method: NetworkMethod,
        headers: [String: String] = [:],
        form: [String: String]? = nil,
        utf8Body: String? = nil,
        decode: DecodeMode = .auto,
        cache: NetworkCacheMode = .default,
        semanticCacheKey: String? = nil,
        referrerUrl: String? = nil
    ) throws {
        guard (1...4096).contains(url.utf16.count) else { throw ProtocolError.invalidRequestUrl }
        guard headers.count <= 32 else { throw ProtocolError.tooManyRequestHeaders }
        guard form == nil || utf8Body == nil else { throw ProtocolError.requestBodyConflict }
        guard method == .post || (form == nil && utf8Body == nil) else { throw ProtocolError.bodyRequiresPost }
        guard method != .post || cache == .networkOnly else { throw ProtocolError.postMustBypassCache }
        if let semanticCacheKey, !Grammar.isSemanticCacheKey(semanticCacheKey) {
            throw ProtocolError.invalidSemanticCacheKey
        }
        self.url = url
        self.method = method
        self.headers = headers
        self.form = form
        self.utf8Body = utf8Body
        self.decode = decode
        self.cache = cache
        self.semanticCacheKey = semanticCacheKey
        self.referrerUrl = referrerUrl
    }
}

public struct SourceNetworkResponse: Hashable, Sendable {
    public let status: Int
    public let finalUrl: String
    public let headers: [String: String]
    public let text: String?
    public let bytes: Data?
    public let decodeUsed: DecodeMode
    public let cacheState: NetworkCacheState
    public let diagnosticId: String

    public init(
        status: Int,
        finalUrl: String,
        headers: [String: String],
        text: String?,
        bytes: Data?,
        decodeUsed: DecodeMode,
        cacheState: NetworkCacheState,
        diagnosticId: String
    ) throws {
        guard (100...599).contains(status) else { throw ProtocolError.invalidHttpStatus }
        guard (text == nil) != (bytes == nil) else { throw ProtocolError.responseBodyRepresentation }
        guard Grammar.isDiagnosticId(diagnosticId) else { throw ProtocolError.invalidDiagnosticId }
        self.status = status
        self.finalUrl = finalUrl
        self.headers = headers
        self.text = text
        self.bytes = bytes
        self.decodeUsed = decodeUsed
        self.cacheState = cacheState
        self.diagnosticId = diagnosticId
    }
}

public enum SourceErrorCode: String, Sendable, Codable, CaseIterable {
    case networkTimeout = "NETWORK_TIMEOUT"
    case networkOffline = "NETWORK_OFFLINE"
    case networkRedirectDisallowed = "NETWORK_REDIRECT_DISALLOWED"
    case networkResponseTooLarge = "NETWORK_RESPONSE_TOO_LARGE"
    case originNotGranted = "ORIGIN_NOT_GRANTED"
    case sessionRequired = "SESSION_REQUIRED"
    case verificationRequired = "VERIFICATION_REQUIRED"
    case malformedSourceResponse = "MALFORMED_SOURCE_RESPONSE"
    case emptySourceResponse = "EMPTY_SOURCE_RESPONSE"
    case extensionRuntimeFailure = "EXTENSION_RUNTIME_FAILURE"
    case extensionTimeout = "EXTENSION_TIMEOUT"
    case extensionCancelled = "EXTENSION_CANCELLED"
}

public struct SourceDiagnostic: Hashable, Sendable {
    public let correlationId: String
    public let stage: String
    public let safeCode: String
    public let status: Int?
    public let origin: String?
    public let redirectCount: Int
    public let decode: DecodeMode?
    public let cacheState: NetworkCacheState?

    public init(
        correlationId: String,
        stage: String,
        safeCode: String,
        status: Int? = nil,
        origin: String? = nil,
        redirectCount: Int = 0,
        decode: DecodeMode? = nil,
        cacheState: NetworkCacheState? = nil
    ) throws {
        guard (8...128).contains(correlationId.utf16.count) else { throw ProtocolError.invalidCorrelationId }
        guard (1...64).contains(stage.utf16.count), (1...128).contains(safeCode.utf16.count) else {
            throw ProtocolError.invalidDiagnostic
        }
        guard (0...5).contains(redirectCount) else { throw ProtocolError.invalidRedirectCount }
        self.correlationId = correlationId
        self.stage = stage
        self.safeCode = safeCode
        self.status = status
        self.origin = origin
        self.redirectCount = redirectCount
        self.decode = decode
        self.cacheState = cacheState
    }
}

public struct SourceException: Error, Hashable, Sendable {
    public let code: SourceErrorCode
    public let diagnostic: SourceDiagnostic

    public init(code: SourceErrorCode, diagnostic: SourceDiagnostic) {
        self.code = code
        self.diagnostic = diagnostic
    }
}
