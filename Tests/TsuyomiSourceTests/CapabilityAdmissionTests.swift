// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// The official Wenku8 manifest declares everything a Host API 1.2.0 package can: an update check,
/// remote targets, and remote remove/move. This host performs none of those, but it has to admit the
/// declaration or the official package cannot be installed at all; admission follows the Android
/// packager's rules so both hosts refuse the same manifests.
final class CapabilityAdmissionTests: XCTestCase {
    private func officialCapabilities() throws -> [String: JSONValue] {
        try XCTUnwrap(try JSONValue.decode(try TestFixtures.data("official-wenku8-0.2.31-capabilities.json")).objectValue)
    }

    private func mutated(_ change: (inout [String: JSONValue]) throws -> Void) throws -> [String: JSONValue] {
        var capabilities = try officialCapabilities()
        try change(&capabilities)
        return capabilities
    }

    private func mutatedPolicy(
        _ name: String,
        _ change: (inout [String: JSONValue]) throws -> Void
    ) throws -> [String: JSONValue] {
        try mutated { capabilities in
            var remoteLibrary = try XCTUnwrap(capabilities.object("remoteLibrary"))
            var policies = try XCTUnwrap(remoteLibrary.object("policies"))
            var policy = try XCTUnwrap(policies.object(name))
            try change(&policy)
            policies[name] = .object(policy)
            remoteLibrary["policies"] = .object(policies)
            capabilities["remoteLibrary"] = .object(remoteLibrary)
        }
    }

    func testTheOfficialWenku8CapabilitiesAreAdmitted() throws {
        let parsed = try HxpCapabilityParser.parse(try officialCapabilities())
        let updateCheck = try XCTUnwrap(parsed.updateCheck)
        XCTAssertEqual(updateCheck.origin.canonical, "https://www.wenku8.net")
        XCTAssertEqual(updateCheck.path, "/modules/article/reader.php")
        XCTAssertEqual(updateCheck.parameters, [.remoteBookId(name: "aid")])
        XCTAssertEqual(parsed.remoteLibrary.writeOperations, ["add", "remove", "move"])
        XCTAssertEqual(Set(parsed.remoteLibrary.policies.keys), [.read, .targets, .add, .remove, .move])
        XCTAssertEqual(parsed.remoteLibrary.policies[.add]?.method, .get)
        XCTAssertEqual(parsed.remoteLibrary.policies[.targets]?.method, .get)
        XCTAssertEqual(parsed.remoteLibrary.policies[.move]?.method, .post)
        XCTAssertTrue(try XCTUnwrap(parsed.remoteLibrary.policies[.move]).parameters.contains(.targetId(name: "target")))
    }

    func testAnUpdateCheckThatIsNotASignedGetIsRefused() throws {
        let posted = try mutated { capabilities in
            var updateCheck = try XCTUnwrap(capabilities.object("updateCheck"))
            updateCheck["method"] = .string("POST")
            capabilities["updateCheck"] = .object(updateCheck)
        }
        XCTAssertThrowsError(try HxpCapabilityParser.parse(posted)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .capabilityPolicyViolation)
        }
        let elsewhere = try mutated { capabilities in
            var updateCheck = try XCTUnwrap(capabilities.object("updateCheck"))
            updateCheck["origin"] = .string("https://elsewhere.example")
            capabilities["updateCheck"] = .object(updateCheck)
        }
        XCTAssertThrowsError(try HxpCapabilityParser.parse(elsewhere)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .capabilityPolicyViolation)
        }
    }

    func testAMoveWithoutATargetOrARemoveByGetIsRefused() throws {
        let untargeted = try mutatedPolicy("move") { policy in
            var parameters = try XCTUnwrap(policy.object("parameters"))
            parameters.removeValue(forKey: "target")
            policy["parameters"] = .object(parameters)
        }
        XCTAssertThrowsError(try HxpCapabilityParser.parse(untargeted)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .capabilityPolicyViolation)
        }
        let fetched = try mutatedPolicy("remove") { policy in policy["method"] = .string("GET") }
        XCTAssertThrowsError(try HxpCapabilityParser.parse(fetched)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .capabilityPolicyViolation)
        }
    }

    /// A policy is a signed request surface for an operation; one for an operation the manifest does
    /// not grant is refused, while a missing policy for an operation this host never issues is not.
    func testAPolicyForAnUngrantedOperationIsRefused() throws {
        let ungranted = try mutated { capabilities in
            var remoteLibrary = try XCTUnwrap(capabilities.object("remoteLibrary"))
            remoteLibrary["writeOperations"] = .array([.string("add"), .string("remove")])
            capabilities["remoteLibrary"] = .object(remoteLibrary)
        }
        XCTAssertThrowsError(try HxpCapabilityParser.parse(ungranted)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .capabilityPolicyViolation)
        }
        let withoutTargets = try mutated { capabilities in
            var remoteLibrary = try XCTUnwrap(capabilities.object("remoteLibrary"))
            var policies = try XCTUnwrap(remoteLibrary.object("policies"))
            policies.removeValue(forKey: "targets")
            remoteLibrary["policies"] = .object(policies)
            capabilities["remoteLibrary"] = .object(remoteLibrary)
        }
        XCTAssertNil(try HxpCapabilityParser.parse(withoutTargets).remoteLibrary.policies[.targets])
    }
}
