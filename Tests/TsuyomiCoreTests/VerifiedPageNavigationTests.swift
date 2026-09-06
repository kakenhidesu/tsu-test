// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class VerifiedPageNavigationTests: XCTestCase {
    private let request = "https://www.wenku8.net/book/1234.htm"
    private let redirected = "https://www.wenku8.net/verify/1234"

    func testAHostLoadedPageSettlesAndBinds() {
        let tracker = VerifiedPageNavigationTracker()
        tracker.start(request)
        tracker.onProvisionalStart(request)
        tracker.onFinish(request)
        XCTAssertEqual(
            tracker.binding(for: request),
            VerifiedPageNavigationBinding(requestUrl: request, pageUrl: request)
        )
    }

    func testAnObservedServerRedirectKeepsTheRequestProvenance() {
        let tracker = VerifiedPageNavigationTracker()
        tracker.start(request)
        tracker.onProvisionalStart(request)
        tracker.onServerRedirect(redirected)
        tracker.onProvisionalStart(redirected)
        tracker.onFinish(redirected)
        XCTAssertEqual(
            tracker.binding(for: redirected),
            VerifiedPageNavigationBinding(requestUrl: request, pageUrl: redirected)
        )
        XCTAssertNil(tracker.binding(for: request))
    }

    func testAUserInitiatedNavigationAbandonsTheBinding() {
        let tracker = VerifiedPageNavigationTracker()
        tracker.start(request)
        tracker.onProvisionalStart(request)
        tracker.onFinish(request)
        tracker.onMainFrameNavigation("https://www.wenku8.net/browsed", userInitiated: true)
        XCTAssertNil(tracker.binding(for: request))
        XCTAssertNil(tracker.binding(for: "https://www.wenku8.net/browsed"))
    }

    func testAnAutomaticNavigationAfterSettlingContinuesTheChain() {
        let tracker = VerifiedPageNavigationTracker()
        tracker.start(request)
        tracker.onProvisionalStart(request)
        tracker.onFinish(request)
        tracker.onMainFrameNavigation(redirected, userInitiated: false)
        XCTAssertNil(tracker.binding(for: request))
        tracker.onProvisionalStart(redirected)
        tracker.onFinish(redirected)
        XCTAssertEqual(
            tracker.binding(for: redirected),
            VerifiedPageNavigationBinding(requestUrl: request, pageUrl: redirected)
        )
    }

    func testNothingBindsBeforeAnExplicitRequest() {
        let tracker = VerifiedPageNavigationTracker()
        tracker.onProvisionalStart(request)
        tracker.onFinish(request)
        XCTAssertNil(tracker.binding(for: request))
    }

    func testClearingRemovesTheBinding() {
        let tracker = VerifiedPageNavigationTracker()
        tracker.start(request)
        tracker.onProvisionalStart(request)
        tracker.onFinish(request)
        tracker.clear()
        XCTAssertNil(tracker.binding(for: request))
    }

    func testCookieHostMatchingFollowsTheDeclaredOrigin() throws {
        func cookie(domain: String) throws -> HTTPCookie {
            try XCTUnwrap(
                HTTPCookie(properties: [.name: "session", .value: "opaque", .domain: domain, .path: "/"])
            )
        }
        XCTAssertTrue(
            ControlledWebLoginSession.matches(cookie: try cookie(domain: "www.wenku8.net"), host: "www.wenku8.net")
        )
        XCTAssertTrue(
            ControlledWebLoginSession.matches(cookie: try cookie(domain: ".wenku8.net"), host: "www.wenku8.net")
        )
        XCTAssertFalse(
            ControlledWebLoginSession.matches(cookie: try cookie(domain: "example.com"), host: "www.wenku8.net")
        )
    }

    /// What the login window may navigate to, including the window a `target="_blank"` link asks for.
    /// The declared host is the boundary; the scheme is not, because the site redirects its own pages
    /// onto plaintext and a window that refuses to follow is a window nothing can be done in.
    func testTheWindowReachesItsDeclaredHostOnEitherScheme() throws {
        let origins: Set<HttpsOrigin> = [try HttpsOrigin("https://www.wenku8.net")]
        func reaches(_ url: String) throws -> Bool {
            ControlledWebLoginSession.isReachable(try XCTUnwrap(URL(string: url)), within: origins)
        }
        XCTAssertTrue(try reaches("https://www.wenku8.net/book/1234.htm"))
        XCTAssertTrue(try reaches("http://www.wenku8.net/book/1234.htm"))
        XCTAssertFalse(try reaches("https://pic.wenku8.com/cover.jpg"), "an undeclared host stays out")
        XCTAssertFalse(try reaches("https://www.wenku8.net:8443/book/1234.htm"), "so does another port")
        XCTAssertFalse(try reaches("file:///etc/passwd"))
        XCTAssertFalse(try reaches("https://user:secret@www.wenku8.net/"))
    }
}
