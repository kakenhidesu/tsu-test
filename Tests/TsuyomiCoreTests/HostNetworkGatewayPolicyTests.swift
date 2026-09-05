// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class HostNetworkGatewayPolicyTests: XCTestCase {
    func testDisallowedOriginAndProtectedHeadersNeverReachTransport() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()

        await assertHostFailure(.disallowedOrigin) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.request(url: "https://outside.example/chapter")
            )
        }
        await assertHostFailure(.headerDisallowed) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.request(headers: ["Cookie": "secret=session"])
            )
        }
        let recorded = await transport.requests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testCacheIsNamespacedByExtensionVersionAndOfflineReturnsStaleMarker() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()
        let request = try NetworkFixture.request(cache: .default, semanticCacheKey: "detail:1234")

        var response = try await gateway.request(grant: grant, request: request)
        XCTAssertEqual(response.cacheState, .miss)
        response = try await gateway.request(grant: grant, request: request)
        XCTAssertEqual(response.cacheState, .fresh)
        var recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)

        let offline = try await gateway.request(
            grant: grant,
            request: try NetworkFixture.request(cache: .offlineOnly, semanticCacheKey: "detail:1234")
        )
        XCTAssertEqual(offline.cacheState, .staleOffline)
        recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)

        let updated = try NetworkFixture.grant(extensionVersion: "0.1.1")
        response = try await gateway.request(grant: updated, request: request)
        XCTAssertEqual(response.cacheState, .miss)
        recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 2)
    }

    func testValidateModeNeverAdmitsRawResponseBeforeCallerValidation() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()
        let validate = try NetworkFixture.request(cache: .validate, semanticCacheKey: "detail:1234")

        let response = try await gateway.request(grant: grant, request: validate)
        XCTAssertEqual(response.cacheState, .validated)
        await assertHostFailure(.offlineMiss) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.request(cache: .offlineOnly, semanticCacheKey: "detail:1234")
            )
        }
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)
    }

    func testRedirectToUndeclaredOriginIsRejectedBeforeFollowingIt() async throws {
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 302,
                finalUrl: request.url,
                headers: ["location": "https://outside.example/redirected"],
                bytes: Data()
            )
        }
        let gateway = HostNetworkGateway(transport: transport)
        await assertHostFailure(.redirectDisallowed) {
            _ = try await gateway.request(grant: try NetworkFixture.grant(), request: try NetworkFixture.request())
        }
    }

    func testHostManagedCookiesAreHiddenAndIsolatedBySourceVersion() async throws {
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 200,
                finalUrl: request.url,
                headers: ["set-cookie": "session=opaque; Path=/; Secure"],
                bytes: Data("fixture".utf8)
            )
        }
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()

        let first = try await gateway.request(grant: grant, request: try NetworkFixture.request())
        _ = try await gateway.request(grant: grant, request: try NetworkFixture.request())
        _ = try await gateway.request(
            grant: try NetworkFixture.grant(extensionVersion: "0.1.1"),
            request: try NetworkFixture.request()
        )

        XCTAssertNil(first.headers["set-cookie"])
        let recorded = await transport.requests()
        XCTAssertEqual(recorded[1].headers["cookie"], "session=opaque")
        XCTAssertNil(recorded[2].headers["cookie"])
    }

    func testCookieNoneDropsServerSetCookie() async throws {
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 200,
                finalUrl: request.url,
                headers: ["set-cookie": "server=unapproved; Path=/; Secure"],
                bytes: Data("fixture".utf8)
            )
        }
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant(cookieMode: .none, cookieOrigins: [])

        await assertHostFailure(.disallowedOrigin) {
            try await gateway.importSourceCookies(
                grant: grant,
                origin: try NetworkFixture.origin("https://www.wenku8.net"),
                rawCookie: "handoff=unapproved"
            )
        }
        _ = try await gateway.request(grant: grant, request: try NetworkFixture.request())
        _ = try await gateway.request(grant: grant, request: try NetworkFixture.request())

        let recorded = await transport.requests()
        XCTAssertNil(recorded[1].headers["cookie"])
    }

    func testSourceScopedCookiesRejectOtherOriginsAndPreserveAllowedHandoff() async throws {
        let www = try NetworkFixture.origin("https://www.wenku8.net")
        let api = try NetworkFixture.origin("https://api.wenku8.net")
        let grant = try NetworkFixture.grant(origins: [www, api], cookieOrigins: [www])
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 200,
                finalUrl: request.url,
                headers: ["set-cookie": "server=approved; Path=/; Secure"],
                bytes: Data("fixture".utf8)
            )
        }
        let gateway = HostNetworkGateway(transport: transport)

        try await gateway.importSourceCookies(grant: grant, origin: www, rawCookie: "handoff=approved")
        await assertHostFailure(.disallowedOrigin) {
            try await gateway.importSourceCookies(grant: grant, origin: api, rawCookie: "handoff=unapproved")
        }

        for url in [
            "https://www.wenku8.net/search",
            "https://www.wenku8.net/detail",
            "https://api.wenku8.net/search",
            "https://api.wenku8.net/detail"
        ] {
            _ = try await gateway.request(grant: grant, request: try NetworkFixture.request(url: url))
        }

        let recorded = await transport.requests()
        XCTAssertEqual(recorded[0].headers["cookie"], "handoff=approved")
        XCTAssertEqual(recorded[1].headers["cookie"], "handoff=approved; server=approved")
        XCTAssertNil(recorded[3].headers["cookie"])
    }

    func testResponseLimitAndLegacyDecoderAreHostEnforced() async throws {
        let oversized = HostNetworkGateway(
            transport: RecordingTransport { request in
                HostHttpResponse(status: 200, finalUrl: request.url, headers: [:], bytes: Data(count: 1_025))
            }
        )
        await assertHostFailure(.responseLimit) {
            _ = try await oversized.request(
                grant: try NetworkFixture.grant(),
                request: try NetworkFixture.request()
            )
        }

        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let encoded = try XCTUnwrap("雾港".data(using: encoding))
        let legacy = HostNetworkGateway(
            transport: RecordingTransport { request in
                HostHttpResponse(status: 200, finalUrl: request.url, headers: [:], bytes: encoded)
            }
        )
        let response = try await legacy.request(
            grant: try NetworkFixture.grant(),
            request: try NetworkFixture.request(decode: .gb18030)
        )
        XCTAssertEqual(response.text, "雾港")
        XCTAssertEqual(response.decodeUsed, .gb18030)
    }

    func testPostIsNeverCachedAndBodyIsHardBounded() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()
        let post = try SourceNetworkRequest(
            url: "https://www.wenku8.net/login",
            method: .post,
            utf8Body: "a=1",
            decode: .utf8,
            cache: .networkOnly
        )
        _ = try await gateway.request(grant: grant, request: post)
        _ = try await gateway.request(grant: grant, request: post)
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 2)

        await assertHostFailure(.bodyLimit) {
            _ = try await gateway.request(
                grant: grant,
                request: try SourceNetworkRequest(
                    url: "https://www.wenku8.net/login",
                    method: .post,
                    utf8Body: String(repeating: "x", count: 65 * 1024),
                    decode: .utf8,
                    cache: .networkOnly
                )
            )
        }
    }

    func testMediaUsesOnlyGrantedOriginReferrerAndSourceScopedCookie() async throws {
        let source = try NetworkFixture.origin("https://www.wenku8.net")
        let cover = try NetworkFixture.origin("https://pic.wenku8.com")
        let grant = try NetworkFixture.grant(origins: [source, cover], cookieOrigins: [source])
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 200,
                finalUrl: request.url,
                headers: ["content-type": "image/jpeg"],
                bytes: Data([1, 2, 3])
            )
        }
        let gateway = HostNetworkGateway(transport: transport)
        try await gateway.importSourceCookies(grant: grant, origin: source, rawCookie: "session=verified")

        let response = try await gateway.fetchMedia(
            grant: grant,
            url: "https://pic.wenku8.com/files/article/image/12/1234/1234.jpg",
            referrerUrl: "https://www.wenku8.net/book/1234.htm"
        )

        XCTAssertEqual(response.contentType, "image/jpeg")
        XCTAssertEqual(response.bytes.count, 3)
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].referrer?.absoluteString, "https://www.wenku8.net/book/1234.htm")
        XCTAssertNil(recorded[0].headers["cookie"])
    }
}
