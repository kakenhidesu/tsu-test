// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class DirectActionTests: XCTestCase {
    private let binding = DirectActionBinding(
        sourceId: "org.tsuyomi.wenku8",
        remoteBookId: "42",
        reconciliationId: "reconcile",
        packageDigest: "digest",
        packageVersion: "0.2.0",
        capabilitySetFingerprint: "capability",
        registryGeneration: 3,
        ownerGeneration: 5
    )

    func testPreAcceptRevokeReturnsBindingAndPreventsAcceptance() async throws {
        let registry = DirectActionTokenRegistry()
        let accepted = Counter()
        let token = await registry.mint(binding) { await accepted.increment(); return true }

        let revoked = await registry.revoke(token)
        XCTAssertEqual(revoked, binding)
        let second = await registry.revoke(token)
        XCTAssertNil(second)
        await assertHostFailure(.cancelled) {
            _ = try await registry.accept(
                sourceId: self.binding.sourceId,
                remoteBookId: self.binding.remoteBookId,
                token: token
            )
        }
        let count = await accepted.value
        XCTAssertEqual(count, 0)
    }

    func testMismatchedIdentityDoesNotConsumeCallback() async throws {
        let registry = DirectActionTokenRegistry()
        let accepted = Counter()
        let token = await registry.mint(binding) { await accepted.increment(); return true }

        await assertHostFailure(.cancelled) {
            _ = try await registry.accept(
                sourceId: self.binding.sourceId,
                remoteBookId: "other",
                token: token
            )
        }
        let count = await accepted.value
        XCTAssertEqual(count, 0)
        let revoked = await registry.revoke(token)
        XCTAssertEqual(revoked, binding)
    }

    func testTokenIsAcceptedOnlyByItsOwnerRegistry() async throws {
        let owner = DirectActionTokenRegistry()
        let unrelated = DirectActionTokenRegistry()
        let accepted = Counter()
        let token = await owner.mint(binding) { await accepted.increment(); return true }

        await assertHostFailure(.cancelled) {
            _ = try await unrelated.accept(
                sourceId: self.binding.sourceId,
                remoteBookId: self.binding.remoteBookId,
                token: token
            )
        }
        let result = try await owner.accept(
            sourceId: binding.sourceId,
            remoteBookId: binding.remoteBookId,
            token: token
        )
        XCTAssertEqual(result, binding)
        let count = await accepted.value
        XCTAssertEqual(count, 1)
    }

    func testGenericContextCannotReachTheSignedAddSurface() async throws {
        let transport = RecordingTransport()
        let gateway = HostNetworkGateway(transport: transport)
        let grant = try NetworkFixture.grant()

        await assertHostFailure(.invalidRequest) {
            _ = try await gateway.request(grant: grant, request: try NetworkFixture.addRequest())
        }
        let readPolicy = try RemoteOperationRequestPolicy(
            origin: try NetworkFixture.origin("https://www.wenku8.net"),
            method: .get,
            path: "/remote/shelf",
            fixedParameters: ["mode": "list"]
        )
        await assertHostFailure(.invalidRequest) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.addRequest(),
                operationContext: try remoteLibraryReadContext(policy: readPolicy, cursor: nil)
            )
        }
        await assertHostFailure(.invalidRequest) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.addRequest(form: ["mode": "list", "bid": "42"])
            )
        }
        let recorded = await transport.requests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testRemoteAddRejectsCacheModesBeforeTokenAcceptance() async throws {
        let transport = RecordingTransport()
        let registry = DirectActionTokenRegistry()
        let gateway = HostNetworkGateway(transport: transport, directActionTokens: registry)
        let accepted = Counter()
        let token = await registry.mint(binding) { await accepted.increment(); return true }
        let cacheablePolicy = try RemoteOperationRequestPolicy(
            origin: try NetworkFixture.origin("https://www.wenku8.net"),
            method: .get,
            path: "/remote/shelf",
            fixedParameters: ["mode": "add"],
            remoteBookIdParameter: "bid"
        )
        let context = try remoteLibraryAddContext(policy: cacheablePolicy, remoteBookId: "42", addToken: token)
        let grant = try NetworkFixture.grant(remoteAddPolicy: cacheablePolicy)

        await assertHostFailure(.invalidRequest) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.request(
                    url: "https://www.wenku8.net/remote/shelf?mode=add&bid=42",
                    cache: .default,
                    semanticCacheKey: "remote-add:42"
                ),
                operationContext: context
            )
        }
        let count = await accepted.value
        XCTAssertEqual(count, 0)
        let recorded = await transport.requests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testRemoteAddAcceptanceIsSingleUseAndRejectionHasZeroTransport() async throws {
        let transport = RecordingTransport()
        let registry = DirectActionTokenRegistry()
        let gateway = HostNetworkGateway(transport: transport, directActionTokens: registry)
        let policy = try NetworkFixture.addPolicy()
        let grant = try NetworkFixture.grant()

        let rejectedToken = await registry.mint(binding) { false }
        await assertHostFailure(.cancelled) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.addRequest(),
                operationContext: try remoteLibraryAddContext(
                    policy: policy,
                    remoteBookId: "42",
                    addToken: rejectedToken
                )
            )
        }
        var recorded = await transport.requests()
        XCTAssertTrue(recorded.isEmpty)

        let acceptedToken = await registry.mint(binding) { true }
        let context = try remoteLibraryAddContext(policy: policy, remoteBookId: "42", addToken: acceptedToken)
        _ = try await gateway.request(
            grant: grant,
            request: try NetworkFixture.addRequest(),
            operationContext: context
        )
        recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)

        await assertHostFailure(.cancelled) {
            _ = try await gateway.request(
                grant: grant,
                request: try NetworkFixture.addRequest(),
                operationContext: context
            )
        }
        recorded = await transport.requests()
        XCTAssertEqual(recorded.count, 1)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
