// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import WebKit

public struct CapturedVerifiedPage: Hashable, Sendable {
    public let requestUrl: String
    public let pageUrl: String
    public let html: String

    public init(requestUrl: String, pageUrl: String, html: String) throws {
        guard isNonBlank(requestUrl), isNonBlank(pageUrl), isNonBlank(html) else {
            throw WebLoginSessionError.emptyCapture
        }
        self.requestUrl = requestUrl
        self.pageUrl = pageUrl
        self.html = html
    }
}

public enum WebLoginSessionError: Error, Equatable, Sendable {
    case alreadyActive
    case notActive
    case originNotDeclared
    case emptyCapture
    case noSettledPage
}

/// A user-visible, one-at-a-time login or verification session. Web content is never handed to an
/// extension: the session only proves which declared-origin page settled and stores the resulting
/// declared-origin cookies and the exact user agent into one encrypted source/origin partition,
/// after the user explicitly finishes. Every termination path wipes the website data store.
@MainActor
public final class ControlledWebLoginSession: NSObject {
    private let sourceId: String
    private let allowedOrigins: Set<HttpsOrigin>
    private let sessions: VerifiedBrowserSessionStore
    private let onBlockedNavigation: (URL) -> Void

    private var webView: WKWebView?
    private var isActive = false
    private let navigation = VerifiedPageNavigationTracker()

    public init(
        sourceId: String,
        allowedOrigins: Set<HttpsOrigin>,
        sessions: VerifiedBrowserSessionStore,
        onBlockedNavigation: @escaping (URL) -> Void = { _ in }
    ) throws {
        guard isNonBlank(sourceId), !allowedOrigins.isEmpty else {
            throw WebLoginSessionError.originNotDeclared
        }
        self.sourceId = sourceId
        self.allowedOrigins = allowedOrigins
        self.sessions = sessions
        self.onBlockedNavigation = onBlockedNavigation
        super.init()
    }

    /// The user agent the transport uses must be identical to the one the WebView presents, or the
    /// site can tell the two apart and hand the host a different page than the user just solved.
    public func open(initialUrl: String, userAgent: String) async throws -> WKWebView {
        guard !isActive else { throw WebLoginSessionError.alreadyActive }
        let initial = try normalizedAllowedUrl(initialUrl)
        guard let initialOrigin = try? ControlledWebLoginSession.origin(of: initial) else {
            throw WebLoginSessionError.originNotDeclared
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = try await restoredUserAgent(initialOrigin) ?? userAgent
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = self
        webView = view
        isActive = true

        try await restoreCookies(into: view)
        guard let url = URL(string: initial) else { throw WebLoginSessionError.originNotDeclared }
        navigation.start(initial)
        view.load(URLRequest(url: url))
        return view
    }

    /// Explicitly loads one paused GET so an allowed-origin redirect chain keeps auditable provenance.
    public func openVerifiedPage(requestUrl: String) throws {
        guard let view = webView, isActive else { throw WebLoginSessionError.notActive }
        let normalized = try normalizedAllowedUrl(requestUrl)
        guard let url = URL(string: normalized) else { throw WebLoginSessionError.originNotDeclared }
        navigation.start(normalized)
        view.load(URLRequest(url: url))
    }

    /// The binding the host needs to re-fetch the settled page through its own transport. The page
    /// bytes are never read out of the WebView: `evaluateJavaScript` and user scripts are forbidden,
    /// so the host refetches with the captured cookies instead.
    public func settledNavigation() throws -> VerifiedPageNavigationBinding {
        guard let view = webView, isActive else { throw WebLoginSessionError.notActive }
        guard let current = view.url?.absoluteString,
              let normalized = try? normalizedAllowedUrl(current),
              let binding = navigation.binding(for: normalized) else {
            throw WebLoginSessionError.noSettledPage
        }
        return binding
    }

    /// Explicit user completion only. Stores no undeclared-origin cookie and always clears state.
    public func finish() async throws {
        defer { Task { await close() } }
        guard let view = webView else { throw WebLoginSessionError.notActive }
        let userAgent = view.customUserAgent ?? ""
        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        for origin in allowedOrigins {
            guard let host = URLComponents(string: origin.canonical)?.host else { continue }
            let matching = cookies.filter { ControlledWebLoginSession.matches(cookie: $0, host: host) }
            guard !matching.isEmpty else { continue }
            let raw = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard let session = try? VerifiedBrowserSession(requestCookies: raw, userAgent: userAgent) else {
                continue
            }
            try await sessions.put(
                try SourceCredentialPartition(sourceId: sourceId, origin: origin),
                session: session
            )
        }
    }

    public func cancel() async {
        await close()
    }

    private func close() async {
        guard let view = webView else {
            isActive = false
            navigation.clear()
            return
        }
        view.stopLoading()
        view.navigationDelegate = nil
        await view.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0)
        )
        webView = nil
        isActive = false
        navigation.clear()
    }

    private func restoredUserAgent(_ origin: HttpsOrigin) async throws -> String? {
        let partition = try SourceCredentialPartition(sourceId: sourceId, origin: origin)
        return try await sessions.snapshot(partition)?.session.userAgent
    }

    private func restoreCookies(into view: WKWebView) async throws {
        let store = view.configuration.websiteDataStore.httpCookieStore
        for origin in allowedOrigins {
            let partition = try SourceCredentialPartition(sourceId: sourceId, origin: origin)
            guard let session = try? await sessions.snapshot(partition)?.session,
                  let host = URLComponents(string: origin.canonical)?.host else { continue }
            for fragment in session.requestCookies.split(separator: ";") {
                let pair = fragment.trimmingCharacters(in: .whitespaces)
                guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else { continue }
                let name = String(pair[pair.startIndex..<separator])
                let value = String(pair[pair.index(after: separator)...])
                guard let cookie = HTTPCookie(properties: [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: "/",
                    .secure: "TRUE"
                ]) else { continue }
                await store.setCookie(cookie)
            }
        }
    }

    private func normalizedAllowedUrl(_ value: String) throws -> String {
        guard var components = URLComponents(string: value) else { throw WebLoginSessionError.originNotDeclared }
        components.fragment = nil
        guard let normalized = components.string else { throw WebLoginSessionError.originNotDeclared }
        let origin = try ControlledWebLoginSession.origin(of: normalized)
        guard allowedOrigins.contains(origin) else { throw WebLoginSessionError.originNotDeclared }
        return normalized
    }

    private func isAllowed(_ url: URL) -> Bool {
        (try? normalizedAllowedUrl(url.absoluteString)) != nil
    }

    nonisolated static func origin(of url: String) throws -> HttpsOrigin {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw WebLoginSessionError.originNotDeclared
        }
        let port = components.port
        let suffix = port.map { $0 != 443 && (1...65_535).contains($0) ? ":\($0)" : "" } ?? ""
        guard let origin = try? HttpsOrigin("https://\(host)\(suffix)") else {
            throw WebLoginSessionError.originNotDeclared
        }
        return origin
    }

    nonisolated static func matches(cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        let lowered = domain.lowercased()
        let target = host.lowercased()
        return target == lowered || target.hasSuffix(".\(lowered)")
    }
}

extension ControlledWebLoginSession: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        guard isAllowed(url) else {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                navigation.clear()
                onBlockedNavigation(url)
            }
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame ?? false,
           let normalized = try? normalizedAllowedUrl(url.absoluteString) {
            navigation.onMainFrameNavigation(
                normalized,
                userInitiated: navigationAction.navigationType != .other
            )
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString, let normalized = try? normalizedAllowedUrl(url) else {
            self.navigation.clear()
            return
        }
        self.navigation.onProvisionalStart(normalized)
    }

    public func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        guard let url = webView.url?.absoluteString, let normalized = try? normalizedAllowedUrl(url) else {
            self.navigation.clear()
            return
        }
        self.navigation.onServerRedirect(normalized)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString, let normalized = try? normalizedAllowedUrl(url) else {
            self.navigation.clear()
            return
        }
        self.navigation.onFinish(normalized)
    }
}
