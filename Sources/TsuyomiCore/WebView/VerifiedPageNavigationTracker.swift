// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The request that produced a settled verified page, and the page it settled on.
public struct VerifiedPageNavigationBinding: Hashable, Sendable {
    public let requestUrl: String
    public let pageUrl: String
}

/// Tracks which top-frame document the host may treat as the answer to one explicit request. Only a
/// page the host itself loaded, followed by server redirects it observed, can settle; any navigation
/// the user starts clears the binding, so a page the user browsed to is never sent to an extension.
final class VerifiedPageNavigationTracker {
    private var requestUrl: String?
    private var currentPageUrl: String?
    private var expectedPageUrl: String?
    private var settled = false

    func start(_ requestUrl: String) {
        self.requestUrl = requestUrl
        currentPageUrl = nil
        expectedPageUrl = requestUrl
        settled = false
    }

    /// A user-initiated navigation abandons the binding; an automatic one continues the chain.
    func onMainFrameNavigation(_ targetUrl: String, userInitiated: Bool) {
        guard requestUrl != nil else { return }
        if userInitiated {
            clear()
            return
        }
        if settled {
            expectedPageUrl = targetUrl
            settled = false
            currentPageUrl = nil
        }
    }

    func onServerRedirect(_ targetUrl: String) {
        guard requestUrl != nil else { return }
        expectedPageUrl = targetUrl
        currentPageUrl = nil
        settled = false
    }

    func onProvisionalStart(_ targetUrl: String) {
        guard requestUrl != nil else { return }
        if expectedPageUrl == targetUrl {
            currentPageUrl = targetUrl
            expectedPageUrl = nil
            settled = false
        } else if !settled {
            currentPageUrl = targetUrl
            expectedPageUrl = nil
        } else {
            clear()
        }
    }

    func onFinish(_ targetUrl: String) {
        guard requestUrl != nil, currentPageUrl == targetUrl, expectedPageUrl == nil else { return }
        settled = true
    }

    func binding(for pageUrl: String) -> VerifiedPageNavigationBinding? {
        guard let requestUrl, settled, expectedPageUrl == nil, currentPageUrl == pageUrl else { return nil }
        return VerifiedPageNavigationBinding(requestUrl: requestUrl, pageUrl: pageUrl)
    }

    func clear() {
        requestUrl = nil
        currentPageUrl = nil
        expectedPageUrl = nil
        settled = false
    }
}
