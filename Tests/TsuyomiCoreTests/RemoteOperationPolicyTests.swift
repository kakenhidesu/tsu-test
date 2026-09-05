// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class RemoteOperationPolicyTests: XCTestCase {
    func testRemoteOperationContextRejectsAlteredLiteralsBeforeTransport() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()
        let context = try remoteLibraryReadContext(
            policy: try RemoteOperationRequestPolicy(
                origin: try NetworkFixture.origin("https://www.wenku8.net"),
                method: .get,
                path: "/remote/shelf",
                fixedParameters: ["mode": "list"],
                cursorParameter: "cursor"
            ),
            cursor: nil
        )

        await assertHostFailure(.invalidRequest) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.request(url: "https://www.wenku8.net/remote/shelf?mode=add"),
                operationContext: context
            )
        }
        var recorded = await transport.requests()
        XCTAssertTrue(recorded.isEmpty)

        _ = try await gateway.request(
            grant: grant,
            request: try NetworkFixture.request(url: "https://www.wenku8.net/remote/shelf?mode=list"),
            operationContext: context
        )
        recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)
    }

    func testCursorAppearsExactlyOnceWhenTheHostHoldsOne() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()
        let policy = try RemoteOperationRequestPolicy(
            origin: try NetworkFixture.origin("https://www.wenku8.net"),
            method: .get,
            path: "/remote/shelf",
            fixedParameters: ["mode": "list"],
            cursorParameter: "cursor"
        )
        let context = try remoteLibraryReadContext(policy: policy, cursor: "page-2")

        await assertHostFailure(.invalidRequest) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.request(url: "https://www.wenku8.net/remote/shelf?mode=list"),
                operationContext: context
            )
        }
        _ = try await gateway.request(
            grant: grant,
            request: try NetworkFixture.request(url: "https://www.wenku8.net/remote/shelf?mode=list&cursor=page-2"),
            operationContext: context
        )
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)
    }

    func testSignedContextFollowsOnlyDeclaredSuccessRedirect() async throws {
        let transport = RecordingTransport { request in
            request.url.path == "/remote/shelf"
                ? HostHttpResponse(
                    status: 302,
                    finalUrl: request.url,
                    headers: ["location": "/remote/complete?status=ok"],
                    bytes: Data()
                )
                : HostHttpResponse(status: 200, finalUrl: request.url, headers: [:], bytes: Data("ok".utf8))
        }
        let policy = try RemoteOperationRequestPolicy(
            origin: try NetworkFixture.origin("https://www.wenku8.net"),
            method: .get,
            path: "/remote/shelf",
            fixedParameters: ["mode": "list"],
            redirects: [
                try RemoteOperationRedirectPolicy(
                    origin: try NetworkFixture.origin("https://www.wenku8.net"),
                    method: .get,
                    path: "/remote/complete",
                    fixedParameters: ["status": "ok"]
                )
            ]
        )
        let result = try await HostNetworkGateway(transport: transport).request(
            grant: try NetworkFixture.grant(),
            request: try NetworkFixture.request(url: "https://www.wenku8.net/remote/shelf?mode=list"),
            operationContext: try remoteLibraryReadContext(policy: policy, cursor: nil)
        )

        XCTAssertEqual(result.text, "ok")
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.map(\.url.path), ["/remote/shelf", "/remote/complete"])
        XCTAssertEqual(recorded.last?.method, .get)
    }

    func testSignedContextRejectsUndeclaredSuccessRedirect() async throws {
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 302,
                finalUrl: request.url,
                headers: ["location": "/remote/complete?status=ok"],
                bytes: Data()
            )
        }
        let policy = try RemoteOperationRequestPolicy(
            origin: try NetworkFixture.origin("https://www.wenku8.net"),
            method: .get,
            path: "/remote/shelf",
            fixedParameters: ["mode": "list"]
        )
        await assertHostFailure(.redirectDisallowed) {
            _ = try await HostNetworkGateway(transport: transport).request(
                grant: try NetworkFixture.grant(),
                request: try NetworkFixture.request(url: "https://www.wenku8.net/remote/shelf?mode=list"),
                operationContext: try remoteLibraryReadContext(policy: policy, cursor: nil)
            )
        }
    }

    func testSignedAddChangesPostToDeclaredGetSuccessTarget() async throws {
        let transport = RecordingTransport { request in
            request.url.path == "/remote/shelf"
                ? HostHttpResponse(
                    status: 302,
                    finalUrl: request.url,
                    headers: ["location": "/remote/complete?status=added"],
                    bytes: Data()
                )
                : HostHttpResponse(status: 200, finalUrl: request.url, headers: [:], bytes: Data("confirmed".utf8))
        }
        let registry = DirectActionTokenRegistry()
        let policy = try RemoteOperationRequestPolicy(
            origin: try NetworkFixture.origin("https://www.wenku8.net"),
            method: .post,
            path: "/remote/shelf",
            fixedParameters: ["mode": "add"],
            remoteBookIdParameter: "bid",
            redirects: [
                try RemoteOperationRedirectPolicy(
                    origin: try NetworkFixture.origin("https://www.wenku8.net"),
                    method: .get,
                    path: "/remote/complete",
                    fixedParameters: ["status": "added"]
                )
            ]
        )
        let token = await registry.mint(
            DirectActionBinding(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "42",
                reconciliationId: "reconcile",
                packageDigest: "digest",
                packageVersion: "0.2.0",
                capabilitySetFingerprint: "capability",
                registryGeneration: 7,
                ownerGeneration: 9
            )
        ) { true }

        let result = try await HostNetworkGateway(transport: transport, directActionTokens: registry).request(
            grant: try NetworkFixture.grant(remoteAddPolicy: policy),
            request: try NetworkFixture.addRequest(),
            operationContext: try remoteLibraryAddContext(policy: policy, remoteBookId: "42", addToken: token)
        )

        XCTAssertEqual(result.text, "confirmed")
        let recorded = await transport.requests()
        XCTAssertEqual(recorded.map(\.method), [.post, .get])
        XCTAssertNil(recorded.last?.body)
    }
}
