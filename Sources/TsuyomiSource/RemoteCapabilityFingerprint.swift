// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

extension ExtensionInstaller {
    /// The fingerprint a remote-write grant is bound to. It is length-prefixed and fully ordered so
    /// that two manifests differ here whenever they differ in anything a remote write depends on:
    /// publisher, source, operations, origins, paths, referrers, parameters, or redirect targets.
    static func remoteCapabilitySetFingerprint(_ manifest: HxpManifest, _ publisherFingerprint: String) -> String {
        var text = ""
        func field(_ name: String, _ value: String) {
            text += "\(name):\(value.utf16.count):\(value)\n"
        }
        field("publisher", publisherFingerprint)
        field("publisher-key-id", manifest.publisherKeyId)
        field("source", manifest.sourceId.value)
        field("remote-read", manifest.capabilities.remoteLibrary.read ? "true" : "false")
        for operation in CanonicalOrder.sorted(manifest.capabilities.remoteLibrary.writeOperations) {
            field("remote-write", operation)
        }
        let policies = manifest.capabilities.remoteLibrary.policies
            .sorted { CanonicalOrder.precedes($0.key.rawValue, $1.key.rawValue) }
            .map(\.value)
        for policy in policies {
            text += "remote-policy\n"
            field("operation", policy.operation.rawValue.uppercased())
            field("origin", policy.origin.canonical)
            field("method", policy.method.rawValue)
            field("path", policy.path)
            field("referrer", policy.referrerPath ?? "")
            for parameter in policy.parameters.sorted(by: parameterPrecedes) {
                text += "remote-parameter\n"
                field("kind", canonicalKind(parameter))
                field("name", parameter.name)
                field("value", canonicalValue(parameter))
            }
            for redirect in policy.redirects.sorted(by: redirectPrecedes) {
                text += "remote-redirect\n"
                field("origin", redirect.origin.canonical)
                field("method", redirect.method.rawValue)
                field("path", redirect.path)
                field("referrer", redirect.referrerPath ?? "")
                for name in CanonicalOrder.sorted(redirect.parameters.keys) {
                    text += "remote-redirect-parameter\n"
                    field("name", name)
                    field("value", redirect.parameters[name] ?? "")
                }
            }
        }
        return Sha256.hex(text)
    }

    private static func canonicalKind(_ parameter: HxpRemoteParameter) -> String {
        switch parameter {
        case .fixed: return "fixed"
        case .remoteBookId: return "remote-book-id"
        case .cursor: return "cursor"
        }
    }

    private static func canonicalValue(_ parameter: HxpRemoteParameter) -> String {
        if case .fixed(_, let value) = parameter { return value }
        return ""
    }

    private static func parameterPrecedes(_ lhs: HxpRemoteParameter, _ rhs: HxpRemoteParameter) -> Bool {
        let byName = CanonicalOrder.compare(lhs.name, rhs.name)
        if byName != 0 { return byName < 0 }
        let byKind = CanonicalOrder.compare(canonicalKind(lhs), canonicalKind(rhs))
        if byKind != 0 { return byKind < 0 }
        return CanonicalOrder.precedes(canonicalValue(lhs), canonicalValue(rhs))
    }

    private static func redirectPrecedes(_ lhs: HxpRemoteRedirectTarget, _ rhs: HxpRemoteRedirectTarget) -> Bool {
        let byOrigin = CanonicalOrder.compare(lhs.origin.canonical, rhs.origin.canonical)
        if byOrigin != 0 { return byOrigin < 0 }
        let byPath = CanonicalOrder.compare(lhs.path, rhs.path)
        if byPath != 0 { return byPath < 0 }
        let byReferrer = CanonicalOrder.compare(lhs.referrerPath ?? "", rhs.referrerPath ?? "")
        if byReferrer != 0 { return byReferrer < 0 }
        return CanonicalOrder.precedes(flatten(lhs.parameters), flatten(rhs.parameters))
    }

    private static func flatten(_ parameters: [String: String]) -> String {
        CanonicalOrder.sorted(parameters.keys)
            .map { name in
                let value = parameters[name] ?? ""
                return "\(name.utf16.count):\(name)\(value.utf16.count):\(value)"
            }
            .joined(separator: "\u{0}")
    }
}
