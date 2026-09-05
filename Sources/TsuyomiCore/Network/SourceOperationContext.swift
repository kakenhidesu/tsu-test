// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Host-minted policy for one remote-library transport operation.
public enum SourceOperationKind: Sendable, Equatable {
    case remoteLibraryRead
    case remoteLibraryAdd
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
    public let referrerPath: String?
    public let redirects: [RemoteOperationRedirectPolicy]

    public init(
        origin: HttpsOrigin,
        method: NetworkMethod,
        path: String,
        fixedParameters: [String: String],
        remoteBookIdParameter: String? = nil,
        cursorParameter: String? = nil,
        referrerPath: String? = nil,
        redirects: [RemoteOperationRedirectPolicy] = []
    ) throws {
        guard isPolicyPath(path), fixedParameters.keys.allSatisfy(isNonBlank) else {
            throw HostNetworkException(.invalidRequest)
        }
        if let remoteBookIdParameter, fixedParameters[remoteBookIdParameter] != nil {
            throw HostNetworkException(.invalidRequest)
        }
        if let cursorParameter,
           fixedParameters[cursorParameter] != nil || cursorParameter == remoteBookIdParameter {
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
        self.referrerPath = referrerPath
        self.redirects = redirects
    }

    /// True when a request would land on the protected remote-write surface, whatever it claims to
    /// be doing. Only an explicitly minted add context may reach that surface.
    func matchesSurface(_ request: SourceNetworkRequest) -> Bool {
        guard let requestOrigin = try? originOf(request.url), let path = pathOf(request.url) else { return false }
        if request.method == method, path == self.path, requestOrigin == origin { return true }
        return redirects.contains { redirect in
            request.method == redirect.method && path == redirect.path && requestOrigin == redirect.origin
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
    let addToken: String?

    init(
        kind: SourceOperationKind,
        policy: RemoteOperationRequestPolicy,
        cursor: String? = nil,
        remoteBookId: String? = nil,
        addToken: String? = nil
    ) throws {
        if kind == .remoteLibraryAdd {
            guard let addToken, isNonBlank(addToken), let remoteBookId, isNonBlank(remoteBookId), cursor == nil else {
                throw HostNetworkException(.invalidRequest)
            }
        } else if remoteBookId != nil {
            throw HostNetworkException(.invalidRequest)
        }
        if let cursor, !isNonBlank(cursor) { throw HostNetworkException(.invalidRequest) }
        self.kind = kind
        self.policy = policy
        self.cursor = cursor
        self.remoteBookId = remoteBookId
        self.addToken = addToken
    }

    /// The cursor parameter appears exactly once when the host holds a cursor and is omitted
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

public func remoteLibraryAddContext(
    policy: RemoteOperationRequestPolicy,
    remoteBookId: String,
    addToken: String
) throws -> SourceOperationContext {
    try SourceOperationContext(
        kind: .remoteLibraryAdd,
        policy: policy,
        remoteBookId: remoteBookId,
        addToken: addToken
    )
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

func pathOf(_ url: String) -> String? {
    URLComponents(string: url)?.percentEncodedPath
}
