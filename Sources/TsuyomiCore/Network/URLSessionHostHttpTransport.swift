// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Platform transport that deliberately does not follow redirects, does not read or write the system
/// cookie store, and does not use the URL cache: `HostNetworkGateway` validates every location
/// against a source grant, and the host owns cookies and caching.
public final class URLSessionHostHttpTransport: HostHttpTransport {
    /// The absolute ceiling any signed manifest may request; a per-grant limit is applied by the
    /// gateway on top of this.
    static let absoluteResponseCeiling = 16 * 1024 * 1024

    private let session: URLSession

    public init(userAgent: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity", "User-Agent": userAgent]
        self.session = URLSession(
            configuration: configuration,
            delegate: HostTransportDelegate(),
            delegateQueue: nil
        )
    }

    public func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = TimeInterval(request.timeoutMs) / 1000.0
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.httpShouldHandleCookies = false
        if let referrer = request.referrer {
            urlRequest.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        if request.body != nil, request.method == .post {
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let failure as URLError {
            throw HostNetworkException(URLSessionHostHttpTransport.map(failure))
        } catch {
            throw HostNetworkException(.transport)
        }
        guard let http = response as? HTTPURLResponse, let finalUrl = http.url else {
            throw HostNetworkException(.transport)
        }
        guard data.count <= request.maximumResponseBytes else { throw HostNetworkException(.responseLimit) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        return HostHttpResponse(status: http.statusCode, finalUrl: finalUrl, headers: headers, bytes: data)
    }

    static func map(_ failure: URLError) -> HostNetworkError {
        switch failure.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed: return .offline
        case .dataLengthExceedsMaximum: return .responseLimit
        default: return .transport
        }
    }
}

private final class HostTransportDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let ceiling = Int64(URLSessionHostHttpTransport.absoluteResponseCeiling)
        completionHandler(response.expectedContentLength > ceiling ? .cancel : .allow)
    }
}
