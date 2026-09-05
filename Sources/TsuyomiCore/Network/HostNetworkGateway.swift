// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Validates every extension-controlled field before a host transport runs. Caches are source and
/// version namespaced; no request header or raw byte leaves this actor through `SourceNetworkResponse`.
public actor HostNetworkGateway {
    private let transport: any HostHttpTransport
    private let cache: any HostNetworkCache
    private let directActionTokens: DirectActionTokenRegistry
    private let cookieJar: SourceCookieJar
    private var busyLanes: Set<String> = []
    private var laneWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        transport: any HostHttpTransport,
        cache: any HostNetworkCache = InMemoryHostNetworkCache(),
        directActionTokens: DirectActionTokenRegistry = DirectActionTokenRegistry()
    ) {
        self.transport = transport
        self.cache = cache
        self.directActionTokens = directActionTokens
        self.cookieJar = SourceCookieJar()
    }

    /// Imports user-approved request cookies into exactly one signed source/version origin scope.
    public func importSourceCookies(
        grant: SourceNetworkGrant,
        origin: HttpsOrigin,
        rawCookie: String
    ) async throws {
        try await cookieJar.seed(grant, origin: origin, rawCookie: rawCookie)
    }

    /// Fetches one display image through the same source/version cookie and verified-identity
    /// transport as source documents. Callers provide only a granted HTTPS URL and canonical referrer.
    public func fetchMedia(
        grant: SourceNetworkGrant,
        url: String,
        referrerUrl: String?
    ) async throws -> HostMediaResponse {
        var current = try allowedUrl(url, grant: grant)
        let referrer = try referrerUrl.map { try allowedUrl($0, grant: grant) }
        for redirectCount in 0...HostResponseDecoding.maximumRedirects {
            let cookies = await cookieJar.requestHeader(grant, url: current)
            let response = try await execute(
                HostHttpRequest(
                    url: current,
                    method: .get,
                    headers: ["accept": "image/jpeg,image/png;q=0.9"].merging(cookies) { _, new in new },
                    decode: .auto,
                    body: nil,
                    referrer: referrer,
                    timeoutMs: grant.requestTimeoutMs,
                    maximumResponseBytes: grant.maximumResponseBytes
                )
            )
            guard response.finalUrl == current else { throw HostNetworkException(.redirectDisallowed) }
            await cookieJar.store(grant, url: current, headers: response.headers)
            if (300...399).contains(response.status) {
                guard redirectCount < HostResponseDecoding.maximumRedirects else {
                    throw HostNetworkException(.redirectLimit)
                }
                guard let location = header(response.headers, "location"),
                      let resolved = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw HostNetworkException(.redirectDisallowed)
                }
                current = try allowedUrl(resolved.absoluteString, grant: grant)
                continue
            }
            guard (200...299).contains(response.status) else { throw HostNetworkException(.transport) }
            guard response.bytes.count <= grant.maximumResponseBytes else {
                throw HostNetworkException(.responseLimit)
            }
            let contentType = (header(response.headers, "content-type") ?? "")
                .split(separator: ";", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard contentType == "image/jpeg" || contentType == "image/png" else {
                throw HostNetworkException(.decode)
            }
            return HostMediaResponse(bytes: response.bytes, contentType: contentType)
        }
        throw HostNetworkException(.redirectLimit)
    }

    public func request(
        grant: SourceNetworkGrant,
        request: SourceNetworkRequest,
        operationContext: SourceOperationContext? = nil
    ) async throws -> SourceNetworkResponse {
        try validateOperationBoundary(grant, request, operationContext)
        let url = try allowedUrl(request.url, grant: grant)
        let referrer = try request.referrerUrl.map { try allowedUrl($0, grant: grant) }
        let body = try HostResponseDecoding.requestBody(request)
        let key = cacheKey(grant, request, url)

        if request.cache == .offlineOnly {
            guard let key, let cached = await cache.get(key) else { throw HostNetworkException(.offlineMiss) }
            return try replacing(cached, cacheState: .staleOffline)
        }
        if request.cache == .default, let key, let cached = await cache.get(key) {
            return try replacing(cached, cacheState: .fresh)
        }

        let lane = "\(grant.sourceId)\u{0}\(grant.extensionVersion)"
        await acquire(lane)
        defer { release(lane) }

        if request.cache == .default, let key, let cached = await cache.get(key) {
            return try replacing(cached, cacheState: .fresh)
        }
        let response = try await executeFollowingRedirects(
            grant: grant,
            initialUrl: url,
            request: request,
            headers: try HostResponseDecoding.allowedHeaders(request.headers),
            body: body,
            referrer: referrer,
            operationContext: operationContext
        )
        guard (100...599).contains(response.status) else { throw HostNetworkException(.transport) }
        guard response.bytes.count <= grant.maximumResponseBytes else { throw HostNetworkException(.responseLimit) }
        let finalUrl = try allowedUrl(response.finalUrl.absoluteString, grant: grant)
        let decoded = try HostResponseDecoding.decode(
            response.bytes,
            requested: request.decode,
            contentType: header(response.headers, "content-type")
        )
        let cacheState: NetworkCacheState
        switch request.cache {
        case .networkOnly: cacheState = .bypassed
        case .validate: cacheState = .validated
        default: cacheState = .miss
        }
        let value = try SourceNetworkResponse(
            status: response.status,
            finalUrl: finalUrl.absoluteString,
            headers: response.headers.filter { HostResponseDecoding.exposedResponseHeaders.contains($0.key.lowercased()) },
            text: decoded.text,
            bytes: nil,
            decodeUsed: decoded.mode,
            cacheState: cacheState,
            diagnosticId: UUID().uuidString
        )
        if let key, request.method != .post, request.cache == .default {
            await cache.put(key, response: value)
        }
        return value
    }

    private func executeFollowingRedirects(
        grant: SourceNetworkGrant,
        initialUrl: URL,
        request: SourceNetworkRequest,
        headers: [String: String],
        body: Data?,
        referrer: URL?,
        operationContext: SourceOperationContext?
    ) async throws -> HostHttpResponse {
        if operationContext?.kind == .remoteLibraryAdd {
            guard let context = operationContext, let remoteBookId = context.remoteBookId,
                  let token = context.addToken else {
                throw HostNetworkException(.invalidRequest)
            }
            try await directActionTokens.accept(
                sourceId: grant.sourceId,
                remoteBookId: remoteBookId,
                token: token
            )
        }
        var url = initialUrl
        var method = request.method
        var currentBody = body
        var currentReferrer = referrer
        var currentRedirect: RemoteOperationRedirectPolicy?
        var redirects = 0
        while true {
            let hop = try rewritten(request, url: url, method: method, followed: redirects > 0)
            if redirects == 0 {
                try validateOperationBoundary(grant, hop, operationContext)
            } else if let operationContext {
                guard let redirect = currentRedirect, method == redirect.method else {
                    throw HostNetworkException(.redirectDisallowed)
                }
                let expectedReferrer = redirect.referrerPath.map { redirect.origin.canonical + $0 }
                guard currentReferrer?.absoluteString == expectedReferrer else {
                    throw HostNetworkException(.redirectDisallowed)
                }
                try validateProtectedAddSurface(grant, hop, operationContext)
            } else {
                try validateOperationBoundary(grant, hop, nil)
            }
            let cookies = await cookieJar.requestHeader(grant, url: url)
            let response = try await execute(
                HostHttpRequest(
                    url: url,
                    method: method,
                    headers: headers.merging(cookies) { _, new in new },
                    decode: request.decode,
                    body: currentBody,
                    referrer: currentReferrer,
                    timeoutMs: grant.requestTimeoutMs,
                    maximumResponseBytes: grant.maximumResponseBytes
                )
            )
            guard response.finalUrl == url else { throw HostNetworkException(.redirectDisallowed) }
            await cookieJar.store(grant, url: url, headers: response.headers)
            guard HostResponseDecoding.redirectStatuses.contains(response.status) else { return response }
            guard let location = header(response.headers, "location") else { return response }
            redirects += 1
            guard redirects <= HostResponseDecoding.maximumRedirects else {
                throw HostNetworkException(.redirectLimit)
            }
            guard let resolved = URL(string: location, relativeTo: url)?.absoluteURL,
                  let next = try? allowedUrl(resolved.absoluteString, grant: grant) else {
                throw HostNetworkException(.redirectDisallowed)
            }
            url = next
            if let operationContext {
                guard let redirect = operationContext.redirect(for: url) else {
                    throw HostNetworkException(.redirectDisallowed)
                }
                if (307...308).contains(response.status), redirect.method != method {
                    throw HostNetworkException(.redirectDisallowed)
                }
                currentRedirect = redirect
                method = redirect.method
                currentBody = nil
                currentReferrer = redirect.referrerPath.flatMap { URL(string: redirect.origin.canonical + $0) }
            } else if response.status == 303 || (method == .post && (301...302).contains(response.status)) {
                method = .get
                currentBody = nil
            }
        }
    }

    private func rewritten(
        _ request: SourceNetworkRequest,
        url: URL,
        method: NetworkMethod,
        followed: Bool
    ) throws -> SourceNetworkRequest {
        let keepsBody = !followed || method == .post
        return try SourceNetworkRequest(
            url: url.absoluteString,
            method: method,
            headers: request.headers,
            form: keepsBody ? request.form : nil,
            utf8Body: keepsBody ? request.utf8Body : nil,
            decode: request.decode,
            cache: request.cache,
            semanticCacheKey: request.semanticCacheKey,
            referrerUrl: request.referrerUrl
        )
    }

    private func validateOperationBoundary(
        _ grant: SourceNetworkGrant,
        _ request: SourceNetworkRequest,
        _ operationContext: SourceOperationContext?
    ) throws {
        if let operationContext, operationContext.kind == .remoteLibraryAdd {
            guard grant.remoteAddPolicy == operationContext.policy, request.cache == .networkOnly else {
                throw HostNetworkException(.invalidRequest)
            }
            try operationContext.validate(request)
            return
        }
        try validateProtectedAddSurface(grant, request, operationContext)
        try operationContext?.validate(request)
    }

    /// The remote-write surface is reachable only through an explicitly minted add context, whatever
    /// URL an extension constructs (`ANDROID_RUNTIME.md` §Source request path).
    private func validateProtectedAddSurface(
        _ grant: SourceNetworkGrant,
        _ request: SourceNetworkRequest,
        _ operationContext: SourceOperationContext?
    ) throws {
        if operationContext?.kind != .remoteLibraryAdd, grant.remoteAddPolicy?.matchesSurface(request) == true {
            throw HostNetworkException(.invalidRequest)
        }
    }

    private func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        do {
            return try await transport.execute(request)
        } catch let failure as HostNetworkException {
            throw failure
        } catch {
            throw HostNetworkException(.transport)
        }
    }

    private func allowedUrl(_ value: String, grant: SourceNetworkGrant) throws -> URL {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            throw HostNetworkException(.invalidRequest)
        }
        let origin = try originOf(value)
        guard grant.origins.contains(origin) else { throw HostNetworkException(.disallowedOrigin) }
        return url
    }

    private func cacheKey(
        _ grant: SourceNetworkGrant,
        _ request: SourceNetworkRequest,
        _ url: URL
    ) -> HostNetworkCacheKey? {
        guard request.method != .post, request.cache != .networkOnly else { return nil }
        return HostNetworkCacheKey(
            sourceId: grant.sourceId,
            extensionVersion: grant.extensionVersion,
            identity: request.semanticCacheKey ?? "\(request.method.rawValue):\(url.absoluteString)",
            decode: request.decode
        )
    }

    private func replacing(
        _ response: SourceNetworkResponse,
        cacheState: NetworkCacheState
    ) throws -> SourceNetworkResponse {
        try SourceNetworkResponse(
            status: response.status,
            finalUrl: response.finalUrl,
            headers: response.headers,
            text: response.text,
            bytes: response.bytes,
            decodeUsed: response.decodeUsed,
            cacheState: cacheState,
            diagnosticId: response.diagnosticId
        )
    }

    private func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }

    private func acquire(_ lane: String) async {
        if busyLanes.contains(lane) {
            await withCheckedContinuation { continuation in
                laneWaiters[lane, default: []].append(continuation)
            }
        } else {
            busyLanes.insert(lane)
        }
    }

    private func release(_ lane: String) {
        if var waiting = laneWaiters[lane], !waiting.isEmpty {
            let next = waiting.removeFirst()
            laneWaiters[lane] = waiting.isEmpty ? nil : waiting
            next.resume()
        } else {
            laneWaiters[lane] = nil
            busyLanes.remove(lane)
        }
    }
}
