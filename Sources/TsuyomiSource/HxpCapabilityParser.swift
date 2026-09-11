// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Capability parsing is where a manifest stops being data and becomes a grant, so every cross-field
/// rule is enforced here: cookies, web login and update checks may only name origins the network
/// capability already grants, and a remote-library surface exists only when the matching policy is
/// signed for it. Admission follows the Android host's rules even for operations this host never
/// performs (remove, move, targets, update checks): a package is accepted or refused on the same
/// grounds everywhere, and an unperformed operation grants nothing.
enum HxpCapabilityParser {
    static func parse(_ value: [String: JSONValue]) throws -> HxpCapabilities {
        try HxpManifestParser.requireKeys(
            value,
            required: ["network", "cookies", "webLogin", "remoteLibrary", "storage"],
            optional: ["home", "updateCheck"]
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

        var updateCheck: HxpUpdateCheckCapability?
        if let raw = value["updateCheck"] {
            guard let object = raw.objectValue else { throw HxpVerificationError.invalidManifest }
            updateCheck = try parseUpdateCheck(object, networkOrigins)
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
            updateCheck: updateCheck,
            remoteLibrary: HxpRemoteLibraryCapability(read: read, writeOperations: writes, policies: policies),
            storageQuotaBytes: try HxpManifestParser.integer(storage, "quotaBytes", 0, 10_485_760)
        )
    }

    private static func parseUpdateCheck(
        _ value: [String: JSONValue],
        _ networkOrigins: Set<HttpsOrigin>
    ) throws -> HxpUpdateCheckCapability {
        try HxpManifestParser.requireKeys(
            value,
            required: ["version", "origin", "method", "path", "parameters"],
            optional: ["referrerPath"]
        )
        guard value.int("version") == 2,
              try HxpManifestParser.text(value, "method") == NetworkMethod.get.rawValue else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        let surface = try parseSurface(value, networkOrigins)
        let parameters = try parseParameters(value, allowed: [.remoteBookId])
        guard (1...16).contains(parameters.count),
              parameters.filter({ if case .remoteBookId = $0 { return true } else { return false } }).count == 1 else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        return HxpUpdateCheckCapability(
            origin: surface.origin,
            path: surface.path,
            referrerPath: surface.referrerPath,
            parameters: parameters
        )
    }

    /// A policy may exist only for an operation that is granted, and the operations this host performs
    /// (`read`, `add`) must have one. The rest (`targets`, `remove`, `move`) are validated when present
    /// and tolerated when absent: this host never issues them, and the acceptance fixtures predate them.
    private static func parsePolicies(
        _ remoteLibrary: [String: JSONValue],
        networkOrigins: Set<HttpsOrigin>,
        read: Bool,
        writes: Set<String>
    ) throws -> [RemoteOperation: HxpRemoteOperationPolicy] {
        var required = Set<String>()
        var allowed = Set<String>()
        if read {
            required.insert("read")
            allowed.insert("targets")
        }
        if writes.contains("add") { required.insert("add") }
        allowed.formUnion(writes.intersection(["remove", "move"]))
        allowed.formUnion(required)
        guard let raw = remoteLibrary["policies"] else {
            if required.isEmpty { return [:] }
            throw HxpVerificationError.capabilityPolicyViolation
        }
        guard let object = raw.objectValue, required.isSubset(of: object.keys),
              Set(object.keys).isSubset(of: allowed) else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        var policies: [RemoteOperation: HxpRemoteOperationPolicy] = [:]
        for (name, value) in object {
            guard let operation = RemoteOperation(rawValue: name) else {
                throw HxpVerificationError.capabilityPolicyViolation
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
        let surface = try parseSurface(value, networkOrigins)
        guard let method = NetworkMethod(rawValue: try HxpManifestParser.text(value, "method")) else {
            throw HxpVerificationError.invalidManifest
        }
        let allowedMethods: Set<NetworkMethod>
        switch operation {
        case .read, .targets: allowedMethods = [.get]
        case .add: allowedMethods = [.get, .post]
        case .remove, .move: allowedMethods = [.post]
        }
        guard allowedMethods.contains(method) else { throw HxpVerificationError.capabilityPolicyViolation }

        let parameters = try parseParameters(value, allowed: [.remoteBookId, .cursor, .targetId])
        var bookIds = 0
        var cursors = 0
        var targetIds = 0
        for parameter in parameters {
            switch parameter {
            case .fixed: break
            case .remoteBookId: bookIds += 1
            case .cursor(let name):
                guard operation == .read, name == "cursor" else {
                    throw HxpVerificationError.capabilityPolicyViolation
                }
                cursors += 1
            case .targetId: targetIds += 1
            }
        }
        let writes: Set<RemoteOperation> = [.add, .remove, .move]
        guard bookIds == (writes.contains(operation) ? 1 : 0),
              targetIds == (operation == .move ? 1 : 0),
              cursors <= 1 else {
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
            origin: surface.origin,
            method: method,
            path: surface.path,
            referrerPath: surface.referrerPath,
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
        let surface = try parseSurface(value, networkOrigins)
        guard try HxpManifestParser.text(value, "method") == NetworkMethod.get.rawValue else {
            throw HxpVerificationError.capabilityPolicyViolation
        }
        var parameters: [String: String] = [:]
        for parameter in try parseParameters(value, allowed: []) {
            if case .fixed(let name, let fixed) = parameter { parameters[name] = fixed }
        }
        return HxpRemoteRedirectTarget(
            origin: surface.origin,
            method: .get,
            path: surface.path,
            referrerPath: surface.referrerPath,
            parameters: parameters
        )
    }

    private static func parseSurface(
        _ value: [String: JSONValue],
        _ networkOrigins: Set<HttpsOrigin>
    ) throws -> (origin: HttpsOrigin, path: String, referrerPath: String?) {
        guard let origin = try? HttpsOrigin(try HxpManifestParser.text(value, "origin")) else {
            throw HxpVerificationError.invalidManifest
        }
        guard networkOrigins.contains(origin) else { throw HxpVerificationError.capabilityPolicyViolation }
        let path = try HxpManifestParser.text(value, "path")
        guard HxpManifestParser.isPolicyPath(path) else { throw HxpVerificationError.invalidManifest }
        let referrerPath = value.string("referrerPath")
        if let referrerPath, !HxpManifestParser.isPolicyPath(referrerPath) {
            throw HxpVerificationError.invalidManifest
        }
        return (origin, path, referrerPath)
    }

    private enum ParameterKind: String {
        case remoteBookId
        case cursor
        case targetId
    }

    /// `fixed` is always admissible; every other kind is admissible only where the caller says so.
    private static func parseParameters(
        _ value: [String: JSONValue],
        allowed: Set<ParameterKind>
    ) throws -> [HxpRemoteParameter] {
        var parameters: [HxpRemoteParameter] = []
        let rawParameters = try HxpManifestParser.object(value, "parameters")
        guard rawParameters.count <= 64 else { throw HxpVerificationError.invalidManifest }
        for name in CanonicalOrder.sorted(rawParameters.keys) {
            guard name.contains(where: { !$0.isWhitespace }), Grammar.codePointCount(name) <= 256,
                  let rule = rawParameters[name]?.objectValue, let kind = rule.string("kind") else {
                throw HxpVerificationError.invalidManifest
            }
            if kind == "fixed" {
                try HxpManifestParser.requireKeys(rule, required: ["kind", "value"])
                parameters.append(
                    .fixed(name: name, value: try HxpManifestParser.bounded(
                        try HxpManifestParser.text(rule, "value"), 0, 8_192
                    ))
                )
                continue
            }
            guard let parsed = ParameterKind(rawValue: kind) else { throw HxpVerificationError.invalidManifest }
            try HxpManifestParser.requireKeys(rule, required: ["kind"])
            guard allowed.contains(parsed) else { throw HxpVerificationError.capabilityPolicyViolation }
            switch parsed {
            case .remoteBookId: parameters.append(.remoteBookId(name: name))
            case .cursor: parameters.append(.cursor(name: name))
            case .targetId: parameters.append(.targetId(name: name))
            }
        }
        return parameters
    }
}
