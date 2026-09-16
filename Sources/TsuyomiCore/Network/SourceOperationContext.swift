// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Host-minted policy for one signed source operation. Reads and target discovery fetch, the
/// three writes change the website and each needs a single-use direct action token, and the update
/// check is a read the host initiates on its own signed surface.
public enum SourceOperationKind: String, Sendable, Equatable, CaseIterable {
    case remoteLibraryRead = "READ"
    case remoteLibraryTargets = "TARGETS"
    case remoteLibraryAdd = "ADD"
    case remoteLibraryRemove = "REMOVE"
    case remoteLibraryMove = "MOVE"
    case updateCheck = "UPDATE_CHECK"

    public var isWrite: Bool {
        self == .remoteLibraryAdd || self == .remoteLibraryRemove || self == .remoteLibraryMove
    }
}

/// A signed, exact redirect destination for one remote-library operation.
public struct RemoteOperationRedirectPolicy: Hashable, Sendable {
    public let origin: HttpsOrigin
    public let method: NetworkMethod
    public let path: String
    public let fixedParameters: [String: String]
    public let referrerPath: String?

    public init(
        origin: HttpsOrigin,
        method: NetworkMethod,
        path: String,
        fixedParameters: [String: String],
        referrerPath: String? = nil
    ) throws {
        guard method == .get, isPolicyPath(path), fixedParameters.keys.allSatisfy(isNonBlank) else {
            throw HostNetworkException(.invalidRequest)
        }
        if let referrerPath, !isPolicyPath(referrerPath) { throw HostNetworkException(.invalidRequest) }
        self.origin = origin
        self.method = method
        self.path = path
        self.fixedParameters = fixedParameters
        self.referrerPath = referrerPath
    }
}

public struct RemoteOperationRequestPolicy: Hashable, Sendable {
    public let origin: HttpsOrigin
    public let method: NetworkMethod
    public let path: String
    public let fixedParameters: [String: String]
    public let remoteBookIdParameter: String?
    public let cursorParameter: String?
    public let targetIdParameter: String?
    public let referrerPath: String?
    public let redirects: [RemoteOperationRedirectPolicy]

    public init(
        origin: HttpsOrigin,
        method: NetworkMethod,
        path: String,
        fixedParameters: [String: String],
        remoteBookIdParameter: String? = nil,
        cursorParameter: String? = nil,
        targetIdParameter: String? = nil,
        referrerPath: String? = nil,
        redirects: [RemoteOperationRedirectPolicy] = []
    ) throws {
        guard isPolicyPath(path), fixedParameters.keys.allSatisfy(isNonBlank) else {
            throw HostNetworkException(.invalidRequest)
        }
        let bound = [remoteBookIdParameter, cursorParameter, targetIdParameter].compactMap { $0 }
        guard Set(bound).count == bound.count, bound.allSatisfy({ fixedParameters[$0] == nil }) else {
            throw HostNetworkException(.invalidRequest)
        }
        if let referrerPath, !isPolicyPath(referrerPath) { throw HostNetworkException(.invalidRequest) }
        guard Set(redirects).count == redirects.count else { throw HostNetworkException(.invalidRequest) }
        self.origin = origin
        self.method = method
        self.path = path
        self.fixedParameters = fixedParameters
        self.remoteBookIdParameter = remoteBookIdParameter
        self.cursorParameter = cursorParameter
        self.targetIdParameter = targetIdParameter
        self.referrerPath = referrerPath
        self.redirects = redirects
    }

    /// True when a request would land on this policy's surface, whatever it claims to be doing and
    /// whatever scheme it arrives on: the plaintext form of that URL is the same surface.
    func matchesSurface(_ request: SourceNetworkRequest) -> Bool {
        guard let path = pathOf(request.url) else { return false }
        if request.method == method, path == self.path,
           declaredOrigin(of: request.url, within: [origin]) != nil {
            return true
        }
        return redirects.contains { redirect in
            request.method == redirect.method && path == redirect.path
                && declaredOrigin(of: request.url, within: [redirect.origin]) != nil
        }
    }

    /// The shape each operation's policy must have (hxp-manifest-v1 §Signed remote-library
    /// operations, §Signed update check v2), checked once when the grant is built.
    func requireShape(for kind: SourceOperationKind) throws {
        switch kind {
        case .remoteLibraryRead:
            guard remoteBookIdParameter == nil, targetIdParameter == nil else { throw HostNetworkException(.invalidRequest) }
        case .remoteLibraryTargets:
            guard remoteBookIdParameter == nil, targetIdParameter == nil, cursorParameter == nil else {
                throw HostNetworkException(.invalidRequest)
            }
        case .remoteLibraryAdd, .remoteLibraryRemove:
            guard remoteBookIdParameter != nil, cursorParameter == nil, targetIdParameter == nil else {
                throw HostNetworkException(.invalidRequest)
            }
        case .remoteLibraryMove:
            guard remoteBookIdParameter != nil, targetIdParameter != nil, cursorParameter == nil else {
                throw HostNetworkException(.invalidRequest)
            }
        case .updateCheck:
            guard method == .get, remoteBookIdParameter != nil, targetIdParameter == nil, cursorParameter == nil,
                  redirects.isEmpty else {
                throw HostNetworkException(.invalidRequest)
            }
        }
    }
}

/// Only host code may create this after resolving immutable manifest policy and direct user intent.
/// `cursor` is nil on the first page and becomes the opaque host-observed cursor thereafter.
public struct SourceOperationContext: Sendable {
    public let kind: SourceOperationKind
    public let policy: RemoteOperationRequestPolicy
    public let cursor: String?
    public let remoteBookId: String?
    public let targetId: String?
    let directActionToken: String?

    init(
        kind: SourceOperationKind,
        policy: RemoteOperationRequestPolicy,
        cursor: String? = nil,
        remoteBookId: String? = nil,
        targetId: String? = nil,
        directActionToken: String? = nil
    ) throws {
        let needsBook = kind.isWrite || kind == .updateCheck
        guard needsBook == (remoteBookId != nil), kind.isWrite == (directActionToken != nil),
              (kind == .remoteLibraryMove) == (targetId != nil),
              cursor == nil || kind == .remoteLibraryRead else {
            throw HostNetworkException(.invalidRequest)
        }
        for value in [cursor, remoteBookId, targetId, directActionToken].compactMap({ $0 }) where !isNonBlank(value) {
            throw HostNetworkException(.invalidRequest)
        }
        self.kind = kind
        self.policy = policy
        self.cursor = cursor
        self.remoteBookId = remoteBookId
        self.targetId = targetId
        self.directActionToken = directActionToken
    }

    /// Every bound parameter appears exactly once when the host holds a value and is omitted
    /// otherwise; the extension can neither add nor drop a parameter on this surface.
    func validate(_ request: SourceNetworkRequest) throws {
        guard request.method == policy.method, request.utf8Body == nil else {
            throw HostNetworkException(.invalidRequest)
        }
        guard let components = URLComponents(string: request.url),
              components.scheme == "https", components.host != nil, components.fragment == nil,
              components.percentEncodedPath == policy.path else {
            throw HostNetworkException(.invalidRequest)
        }
        guard let origin = try? originOf(request.url) else { throw HostNetworkException(.invalidRequest) }
        guard origin == policy.origin else { throw HostNetworkException(.disallowedOrigin) }
        var expected = policy.fixedParameters
        if let name = policy.cursorParameter, let cursor { expected[name] = cursor }
        if let name = policy.remoteBookIdParameter, let remoteBookId { expected[name] = remoteBookId }
        if let name = policy.targetIdParameter, let targetId { expected[name] = targetId }
        let actual: [String: String]
        switch request.method {
        case .get, .head: actual = try decodeQuery(components.percentEncodedQuery)
        case .post: actual = request.form ?? [:]
        }
        guard actual == expected else { throw HostNetworkException(.invalidRequest) }
        let expectedReferrer = policy.referrerPath.map { policy.origin.canonical + $0 }
        guard request.referrerUrl == expectedReferrer else { throw HostNetworkException(.invalidRequest) }
    }

    func redirect(for url: URL) -> RemoteOperationRedirectPolicy? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.fragment == nil,
              let origin = try? originOf(url.absoluteString),
              let parameters = try? decodeQuery(components.percentEncodedQuery) else { return nil }
        let matches = policy.redirects.filter { redirect in
            components.percentEncodedPath == redirect.path
                && origin == redirect.origin
                && parameters == redirect.fixedParameters
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func decodeQuery(_ rawQuery: String?) throws -> [String: String] {
        guard let rawQuery, !rawQuery.isEmpty else { return [:] }
        var values: [String: String] = [:]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                throw HostNetworkException(.invalidRequest)
            }
            let name = String(pair[pair.startIndex..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard let decodedName = name.removingPercentEncoding,
                  let decodedValue = value.removingPercentEncoding else {
                throw HostNetworkException(.invalidRequest)
            }
            guard values.updateValue(decodedValue, forKey: decodedName) == nil else {
                throw HostNetworkException(.invalidRequest)
            }
        }
        return values
    }
}

public func remoteLibraryReadContext(
    policy: RemoteOperationRequestPolicy,
    cursor: String?
) throws -> SourceOperationContext {
    try SourceOperationContext(kind: .remoteLibraryRead, policy: policy, cursor: cursor)
}

public func remoteLibraryTargetsContext(policy: RemoteOperationRequestPolicy) throws -> SourceOperationContext {
    try SourceOperationContext(kind: .remoteLibraryTargets, policy: policy)
}

public func remoteLibraryAddContext(
    policy: RemoteOperationRequestPolicy,
    remoteBookId: String,
    directActionToken: String
) throws -> SourceOperationContext {
    try SourceOperationContext(
        kind: .remoteLibraryAdd,
        policy: policy,
        remoteBookId: remoteBookId,
        directActionToken: directActionToken
    )
}

public func remoteLibraryRemoveContext(
    policy: RemoteOperationRequestPolicy,
    remoteBookId: String,
    directActionToken: String
) throws -> SourceOperationContext {
    try SourceOperationContext(
        kind: .remoteLibraryRemove,
        policy: policy,
        remoteBookId: remoteBookId,
        directActionToken: directActionToken
    )
}

public func remoteLibraryMoveContext(
    policy: RemoteOperationRequestPolicy,
    remoteBookId: String,
    targetId: String,
    directActionToken: String
) throws -> SourceOperationContext {
    try SourceOperationContext(
        kind: .remoteLibraryMove,
        policy: policy,
        remoteBookId: remoteBookId,
        targetId: targetId,
        directActionToken: directActionToken
    )
}

public func updateCheckContext(
    policy: RemoteOperationRequestPolicy,
    remoteBookId: String
) throws -> SourceOperationContext {
    try SourceOperationContext(kind: .updateCheck, policy: policy, remoteBookId: remoteBookId)
}

func isPolicyPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("?") && !path.contains("#")
}

func isNonBlank(_ value: String) -> Bool { value.contains { !$0.isWhitespace } }

/// The origin of an absolute HTTPS URL, with the default port folded away.
func originOf(_ url: String) throws -> HttpsOrigin {
    guard let components = URLComponents(string: url),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil else {
        throw HostNetworkException(.invalidRequest)
    }
    let port = components.port
    let suffix = port.map { $0 != 443 && (1...65_535).contains($0) ? ":\($0)" : "" } ?? ""
    guard let origin = try? HttpsOrigin("https://\(host)\(suffix)") else {
        throw HostNetworkException(.invalidRequest)
    }
    return origin
}

/// The declared origin a URL belongs to when the scheme is not what decides it. A site that
/// redirects its own pages onto plain http still serves the same origin as far as a grant is
/// concerned, and the controlled login window already follows such a chain, so a session captured
/// there would otherwise be unusable. Host and port must still match a declared origin exactly:
/// the scheme is the only thing relaxed, and nothing the host or an extension *asks* for goes
/// through here — only a destination the site itself chose.
func declaredOrigin(of url: String, within origins: Set<HttpsOrigin>) -> HttpsOrigin? {
    guard let components = URLComponents(string: url),
          let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = components.host?.lowercased(), !host.isEmpty,
          components.user == nil, components.password == nil else {
        return nil
    }
    return origins.first { declared in
        guard let declaredComponents = URLComponents(string: declared.canonical),
              declaredComponents.host?.lowercased() == host else { return false }
        guard let port = components.port else { return true }
        return port == declaredComponents.port ?? (scheme == "https" ? 443 : 80)
    }
}

func pathOf(_ url: String) -> String? {
    URLComponents(string: url)?.percentEncodedPath
}
