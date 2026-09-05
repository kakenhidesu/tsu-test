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
}
