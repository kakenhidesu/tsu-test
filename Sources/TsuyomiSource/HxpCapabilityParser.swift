// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Capability parsing is where a manifest stops being data and becomes a grant, so every cross-field
/// rule is enforced here: cookies and web login may only name origins the network capability already
/// grants, and a remote-write surface exists only when the matching policy is signed for it.
enum HxpCapabilityParser {
    static func parse(_ value: [String: JSONValue]) throws -> HxpCapabilities {
        try HxpManifestParser.requireKeys(
            value,
            required: ["network", "cookies", "webLogin", "remoteLibrary", "storage"],
            optional: ["home"]
        )
        let network = try HxpManifestParser.object(value, "network")
        try HxpManifestParser.requireKeys(
            network,
            required: ["origins", "maxConcurrentRequests", "requestTimeoutMs", "maxResponseBytes"]
        )
        let networkOrigins = try HxpManifestParser.originSet(network, "origins", requireNonEmpty: true)
        let networkCapability = HxpNetworkCapability(
            origins: networkOrigins,
            maximumConcurrentRequests: try HxpManifestParser.integer(network, "maxConcurrentRequests", 1, 8),
            requestTimeoutMs: try HxpManifestParser.integer(network, "requestTimeoutMs", 1_000, 120_000),
            maximumResponseBytes: try HxpManifestParser.integer(network, "maxResponseBytes", 1_024, 16_777_216)
        )

        let cookies = try HxpManifestParser.object(value, "cookies")
        try HxpManifestParser.requireKeys(cookies, required: ["mode", "origins"])
        let cookieMode = try HxpManifestParser.text(cookies, "mode")
        guard cookieMode == "none" || cookieMode == "sourceScoped" else {
            throw HxpVerificationError.invalidManifest
        }
        let cookieOrigins = try HxpManifestParser.originSet(cookies, "origins")
        if cookieMode == "none", !cookieOrigins.isEmpty { throw HxpVerificationError.capabilityPolicyViolation }
        guard cookieOrigins.isSubset(of: networkOrigins) else {
            throw HxpVerificationError.capabilityPolicyViolation
        }

        let webLogin = try HxpManifestParser.object(value, "webLogin")
        try HxpManifestParser.requireKeys(webLogin, required: ["enabled", "origins"])
        let webLoginEnabled = try HxpManifestParser.flag(webLogin, "enabled")
        let webLoginOrigins = try HxpManifestParser.originSet(webLogin, "origins")
        if !webLoginEnabled, !webLoginOrigins.isEmpty { throw HxpVerificationError.capabilityPolicyViolation }
        guard webLoginOrigins.isSubset(of: networkOrigins) else {
            throw HxpVerificationError.capabilityPolicyViolation
        }

        var homeEnabled = false
        if let home = value.object("home") {
            try HxpManifestParser.requireKeys(home, required: ["enabled"])
            homeEnabled = try HxpManifestParser.flag(home, "enabled")
        } else if value["home"] != nil {
            throw HxpVerificationError.invalidManifest
        }

        let remoteLibrary = try HxpManifestParser.object(value, "remoteLibrary")
        try HxpManifestParser.requireKeys(
            remoteLibrary,
            required: ["read", "writeOperations"],
            optional: ["policies"]
        )
        let read = try HxpManifestParser.flag(remoteLibrary, "read")
        let rawWrites = try HxpManifestParser.array(remoteLibrary, "writeOperations")
        var writes = Set<String>()
        for item in rawWrites {
            guard let name = item.stringValue, ["add", "remove", "move"].contains(name),
                  writes.insert(name).inserted else {
                throw HxpVerificationError.invalidManifest
            }
        }
        let policies = try parsePolicies(remoteLibrary, networkOrigins: networkOrigins, read: read, writes: writes)
        let storage = try HxpManifestParser.object(value, "storage")
        try HxpManifestParser.requireKeys(storage, required: ["quotaBytes"])

        return HxpCapabilities(
            network: networkCapability,
            cookies: HxpCookieCapability(sourceScoped: cookieMode == "sourceScoped", origins: cookieOrigins),
            webLogin: HxpWebLoginCapability(enabled: webLoginEnabled, origins: webLoginOrigins),
            home: HxpHomeCapability(enabled: homeEnabled),
            remoteLibrary: HxpRemoteLibraryCapability(read: read, writeOperations: writes, policies: policies),
            storageQuotaBytes: try HxpManifestParser.integer(storage, "quotaBytes", 0, 10_485_760)
        )
    }

    private static func parsePolicies(
        _ remoteLibrary: [String: JSONValue],
        networkOrigins: Set<HttpsOrigin>,
        read: Bool,
        writes: Set<String>
    ) throws -> [RemoteOperation: HxpRemoteOperationPolicy] {
        var required = Set<String>()
        if read { required.insert("read") }
        if writes.contains("add") { required.insert("add") }
        guard let raw = remoteLibrary["policies"] else {
            if required.isEmpty { return [:] }
            throw HxpVerificationError.capabilityPolicyViolation
        }
        guard let object = raw.objectValue, Set(object.keys) == required else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        var policies: [RemoteOperation: HxpRemoteOperationPolicy] = [:]
        for (name, value) in object {
            let operation: RemoteOperation
            switch name {
            case "read": operation = .read
            case "add": operation = .add
            default: throw HxpVerificationError.capabilityPolicyViolation
            }
            guard let policyObject = value.objectValue else { throw HxpVerificationError.invalidManifest }
            policies[operation] = try parsePolicy(operation, policyObject, networkOrigins)
        }
        return policies
    }

    private static func parsePolicy(
        _ operation: RemoteOperation,
        _ value: [String: JSONValue],
        _ networkOrigins: Set<HttpsOrigin>
    ) throws -> HxpRemoteOperationPolicy {
        try HxpManifestParser.requireKeys(
            value,
            required: ["origin", "method", "path", "parameters"],
            optional: ["referrerPath", "redirects"]
        )
        guard let origin = try? HttpsOrigin(try HxpManifestParser.text(value, "origin")) else {
            throw HxpVerificationError.invalidManifest
        }
        guard networkOrigins.contains(origin) else { throw HxpVerificationError.capabilityPolicyViolation }
        guard let method = NetworkMethod(rawValue: try HxpManifestParser.text(value, "method")) else {
            throw HxpVerificationError.invalidManifest
        }
        let expectedMethod: NetworkMethod = operation == .read ? .get : .post
        guard method == expectedMethod else { throw HxpVerificationError.capabilityPolicyViolation }
        let path = try HxpManifestParser.text(value, "path")
        guard HxpManifestParser.isPolicyPath(path) else { throw HxpVerificationError.invalidManifest }
        let referrerPath = value.string("referrerPath")
        if let referrerPath, !HxpManifestParser.isPolicyPath(referrerPath) {
            throw HxpVerificationError.invalidManifest
        }

        var parameters: [HxpRemoteParameter] = []
        let rawParameters = try HxpManifestParser.object(value, "parameters")
        for name in CanonicalOrder.sorted(rawParameters.keys) {
            guard isNonBlank(name), Grammar.codePointCount(name) <= 256,
                  let rule = rawParameters[name]?.objectValue else {
                throw HxpVerificationError.invalidManifest
            }
            switch rule.string("kind") {
            case "fixed":
                try HxpManifestParser.requireKeys(rule, required: ["kind", "value"])
                parameters.append(
                    .fixed(name: name, value: try HxpManifestParser.bounded(
                        try HxpManifestParser.text(rule, "value"), 0, 8_192
                    ))
                )
            case "remoteBookId":
                try HxpManifestParser.requireKeys(rule, required: ["kind"])
                guard operation == .add else { throw HxpVerificationError.capabilityPolicyViolation }
                parameters.append(.remoteBookId(name: name))
            case "cursor":
                try HxpManifestParser.requireKeys(rule, required: ["kind"])
                guard operation == .read, name == "cursor" else {
                    throw HxpVerificationError.capabilityPolicyViolation
                }
                parameters.append(.cursor(name: name))
            default:
                throw HxpVerificationError.invalidManifest
            }
        }
        let remoteBookIdCount = parameters.filter { if case .remoteBookId = $0 { return true } else { return false } }
        let cursorCount = parameters.filter { if case .cursor = $0 { return true } else { return false } }
        guard remoteBookIdCount.count == (operation == .add ? 1 : 0), cursorCount.count <= 1 else {
            throw HxpVerificationError.capabilityPolicyViolation
        }

        var redirects: [HxpRemoteRedirectTarget] = []
        if let rawRedirects = value["redirects"] {
            guard let items = rawRedirects.arrayValue else { throw HxpVerificationError.invalidManifest }
            for item in items {
                guard let redirect = item.objectValue else { throw HxpVerificationError.invalidManifest }
                redirects.append(try parseRedirect(redirect, networkOrigins))
            }
        }
        guard redirects.count <= 5, Set(redirects).count == redirects.count else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        return HxpRemoteOperationPolicy(
            operation: operation,
            origin: origin,
            method: method,
            path: path,
            referrerPath: referrerPath,
            parameters: parameters,
            redirects: redirects
        )
    }

    private static func parseRedirect(
        _ value: [String: JSONValue],
        _ networkOrigins: Set<HttpsOrigin>
    ) throws -> HxpRemoteRedirectTarget {
        try HxpManifestParser.requireKeys(
            value,
            required: ["origin", "method", "path", "parameters"],
            optional: ["referrerPath"]
        )
        guard let origin = try? HttpsOrigin(try HxpManifestParser.text(value, "origin")) else {
            throw HxpVerificationError.invalidManifest
        }
        guard networkOrigins.contains(origin) else { throw HxpVerificationError.capabilityPolicyViolation }
        guard try HxpManifestParser.text(value, "method") == NetworkMethod.get.rawValue else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        let path = try HxpManifestParser.text(value, "path")
        guard HxpManifestParser.isPolicyPath(path) else { throw HxpVerificationError.invalidManifest }
        let referrerPath = value.string("referrerPath")
        if let referrerPath, !HxpManifestParser.isPolicyPath(referrerPath) {
            throw HxpVerificationError.invalidManifest
        }
        var parameters: [String: String] = [:]
        let rawParameters = try HxpManifestParser.object(value, "parameters")
        for (name, rule) in rawParameters {
            guard isNonBlank(name), Grammar.codePointCount(name) <= 256,
                  let ruleObject = rule.objectValue else {
                throw HxpVerificationError.invalidManifest
            }
            try HxpManifestParser.requireKeys(ruleObject, required: ["kind", "value"])
            guard ruleObject.string("kind") == "fixed" else {
                throw HxpVerificationError.capabilityPolicyViolation
            }
            parameters[name] = try HxpManifestParser.bounded(
                try HxpManifestParser.text(ruleObject, "value"), 0, 8_192
            )
        }
        return HxpRemoteRedirectTarget(
            origin: origin,
            method: .get,
            path: path,
            referrerPath: referrerPath,
            parameters: parameters
        )
    }
}
