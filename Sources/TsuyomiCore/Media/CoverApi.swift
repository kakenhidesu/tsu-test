// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import UIKit

public struct CoverMediaPayload: Sendable {
    public let bytes: Data
    public let contentType: String

    public init(bytes: Data, contentType: String) {
        self.bytes = bytes
        self.contentType = contentType
    }
}

/// The host-owned transport a cover is fetched through. Feature code never sees the cover URL.
public protocol CoverMediaFetcher: Sendable {
    func fetch(url: String, referrerUrl: String?) async throws -> CoverMediaPayload
}

public struct FallbackSpec: Hashable, Sendable {
    public let title: String
    public let sourceLabel: String?

    public init(title: String, sourceLabel: String?) {
        self.title = title
        self.sourceLabel = sourceLabel
    }
}

public struct CoverRequest: Sendable {
    public let sourceId: String
    public let packageRevision: String
    public let credentialRevision: String
    public let transportUrl: String
    public let referrerUrl: String?
    public let targetWidthPx: Int
    public let targetHeightPx: Int
    public let fallback: FallbackSpec

    public init(
        sourceId: String,
        packageRevision: String,
        credentialRevision: String,
        transportUrl: String,
        referrerUrl: String? = nil,
        targetWidthPx: Int,
        targetHeightPx: Int,
        fallback: FallbackSpec
    ) throws {
        guard isNonBlank(sourceId), isNonBlank(packageRevision), isNonBlank(credentialRevision),
              targetWidthPx > 0, targetHeightPx > 0 else {
            throw MediaLoadError.invalidUrl
        }
        self.sourceId = sourceId
        self.packageRevision = packageRevision
        self.credentialRevision = credentialRevision
        self.transportUrl = transportUrl
        self.referrerUrl = referrerUrl
        self.targetWidthPx = targetWidthPx
        self.targetHeightPx = targetHeightPx
        self.fallback = fallback
    }
}

public enum CoverFailureReason: String, Sendable, CaseIterable {
    case invalidReference = "INVALID_REFERENCE"
    case originNotGranted = "ORIGIN_NOT_GRANTED"
    case network = "NETWORK"
    case responseRejected = "RESPONSE_REJECTED"
    case decodeFailed = "DECODE_FAILED"
}

public enum CoverUiState: Sendable {
    case absent(fallback: FallbackSpec)
    case loading(fallback: FallbackSpec)
    case ready(UIImage)
    case staleReady(UIImage, provenance: String)
    case failed(reason: CoverFailureReason, fallback: FallbackSpec)
    case fallback(FallbackSpec)
}

public enum MediaLoadError: Error, Equatable, Sendable {
    case invalidUrl
    case originNotGranted
    case httpFailure
    case redirectLimit
    case responseTooLarge
    case unsupportedContent
    case decodeFailed

    var publicReason: CoverFailureReason {
        switch self {
        case .invalidUrl: return .invalidReference
        case .originNotGranted: return .originNotGranted
        case .httpFailure, .redirectLimit: return .network
        case .responseTooLarge, .unsupportedContent: return .responseRejected
        case .decodeFailed: return .decodeFailed
        }
    }
}

/// Exact HTTPS-origin grant derived from a verified source manifest.
public struct MediaOriginPolicy: Sendable {
    private let allowed: Set<String>

    public init(origins: Set<HttpsOrigin>) throws {
        guard !origins.isEmpty else { throw MediaLoadError.originNotGranted }
        self.allowed = Set(origins.map(\.canonical))
    }

    public func requireAllowed(_ url: String) throws -> String {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw MediaLoadError.invalidUrl
        }
        let port = components.port
        let suffix = port.map { $0 != 443 ? ":\($0)" : "" } ?? ""
        guard let origin = try? HttpsOrigin("https://\(host)\(suffix)") else { throw MediaLoadError.invalidUrl }
        guard allowed.contains(origin.canonical) else { throw MediaLoadError.originNotGranted }
        return url
    }
}
