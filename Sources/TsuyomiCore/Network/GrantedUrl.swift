// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The three ways a URL is admitted into a source's grant. They differ only in who chose the URL,
/// and that is the whole of the plaintext rule, so they are kept where the difference is visible.
enum GrantedUrl {
    /// A URL an extension asked for. Always HTTPS: the host never initiates plaintext.
    static func requested(_ value: String, grant: SourceNetworkGrant) throws -> URL {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            throw HostNetworkException(.invalidRequest)
        }
        let origin = try originOf(value)
        guard grant.origins.contains(origin) else { throw HostNetworkException(.disallowedOrigin) }
        return url
    }

    /// A destination the site itself chose — a `Location` it sent. It may fall back to plain http,
    /// because a site that redirects its own pages off HTTPS is otherwise unreachable and the login
    /// window already follows the same chain. Host and port still have to belong to a granted
    /// origin, so the scheme is the only thing relaxed.
    static func reachable(_ value: String, grant: SourceNetworkGrant) throws -> URL {
        guard let url = URL(string: value), declaredOrigin(of: value, within: grant.origins) != nil else {
            throw HostNetworkException(.disallowedOrigin)
        }
        return url
    }

    /// The URL a response settled on, restated in the origin the extension declared. A grant can
    /// only name HTTPS origins, so an extension has no way to represent the plaintext form of one:
    /// handed back the http URL a redirect landed on, it rejects its own page. Path, query and
    /// fragment are untouched — only the origin is put back into its declared form.
    static func settled(_ value: URL, grant: SourceNetworkGrant) throws -> String {
        guard let origin = declaredOrigin(of: value.absoluteString, within: grant.origins),
              var components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              let declared = URLComponents(string: origin.canonical) else {
            throw HostNetworkException(.disallowedOrigin)
        }
        components.scheme = declared.scheme
        components.port = declared.port
        guard let restated = components.string else { throw HostNetworkException(.disallowedOrigin) }
        return restated
    }
}
