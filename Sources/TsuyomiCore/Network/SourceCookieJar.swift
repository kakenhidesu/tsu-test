// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Cookies are partitioned by `(sourceId, extensionVersion)` and never reach `HTTPCookieStorage`.
/// An extension can neither read a cookie value nor cause one to be sent to an ungranted origin.
actor SourceCookieJar {
    private struct Scope: Hashable {
        let sourceId: String
        let extensionVersion: String
    }

    private struct StoredCookie {
        let name: String
        let value: String
        let domain: String
        let hostOnly: Bool
        let path: String
        let expiresAt: Date?

        func matches(host: String, path requestPath: String) -> Bool {
            let domainMatches = hostOnly ? host == domain : host == domain || host.hasSuffix(".\(domain)")
            return domainMatches && requestPath.hasPrefix(path)
        }

        func hasExpired(_ now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
    }

    private var cookies: [Scope: [StoredCookie]] = [:]
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    func requestHeader(_ grant: SourceNetworkGrant, url: URL) -> [String: String] {
        guard let origin = declaredOrigin(of: url.absoluteString, within: grant.origins),
              grant.allowsCookies(origin) else { return [:] }
        let scope = Scope(sourceId: grant.sourceId, extensionVersion: grant.extensionVersion)
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        let now = clock()
        var entries = cookies[scope] ?? []
        entries.removeAll { $0.hasExpired(now) }
        cookies[scope] = entries
        let value = entries
            .filter { $0.matches(host: host, path: path) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return value.isEmpty ? [:] : ["cookie": value]
    }

    /// Imports user-approved request cookies into exactly one signed source/version origin scope.
    func seed(_ grant: SourceNetworkGrant, origin: HttpsOrigin, rawCookie: String) throws {
        guard grant.allowsCookies(origin) else { throw HostNetworkException(.disallowedOrigin) }
        guard let host = URLComponents(string: origin.canonical)?.host?.lowercased() else {
            throw HostNetworkException(.invalidRequest)
        }
        let scope = Scope(sourceId: grant.sourceId, extensionVersion: grant.extensionVersion)
        var entries = cookies[scope] ?? []
        for pair in rawCookie.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "="), separator != trimmed.startIndex else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard isCookieName(name), !value.unicodeScalars.contains("\u{0}") else { continue }
            entries.removeAll { $0.name == name && $0.domain == host && $0.path == "/" }
            entries.append(
                StoredCookie(name: name, value: value, domain: host, hostOnly: true, path: "/", expiresAt: nil)
            )
        }
        cookies[scope] = entries
    }

    func store(_ grant: SourceNetworkGrant, url: URL, headers: [String: String]) {
        guard let origin = declaredOrigin(of: url.absoluteString, within: grant.origins),
              grant.allowsCookies(origin) else { return }
        let scope = Scope(sourceId: grant.sourceId, extensionVersion: grant.extensionVersion)
        let requestHost = (url.host ?? "").lowercased()
        var entries = cookies[scope] ?? []
        let now = clock()
        for (name, value) in headers where name.lowercased() == "set-cookie" {
            guard let parsed = SetCookie(header: value, now: now) else { continue }
            let domain = parsed.domain?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() ?? ""
            if !domain.isEmpty, requestHost != domain, !requestHost.hasSuffix(".\(domain)") { continue }
            let stored = StoredCookie(
                name: parsed.name,
                value: parsed.value,
                domain: domain.isEmpty ? requestHost : domain,
                hostOnly: domain.isEmpty,
                path: parsed.path.map { $0.hasPrefix("/") ? $0 : "/" } ?? "/",
                expiresAt: parsed.expiresAt
            )
            entries.removeAll { $0.name == stored.name && $0.domain == stored.domain && $0.path == stored.path }
            if !stored.hasExpired(now) { entries.append(stored) }
        }
        cookies[scope] = entries
    }

    private func isCookieName(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = Set("!#$%&'*+.^_`|~-".unicodeScalars)
        return value.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
                || allowed.contains(scalar)
        }
    }
}

/// One `Set-Cookie` header. Only the attributes the host acts on are parsed; everything else in the
/// header is discarded rather than stored.
struct SetCookie {
    let name: String
    let value: String
    let domain: String?
    let path: String?
    let expiresAt: Date?

    init?(header: String, now: Date) {
        var parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        let pair = parts.removeFirst()
        guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else { return nil }
        self.name = String(pair[pair.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
        self.value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var domain: String?
        var path: String?
        var maxAge: Int?
        var expires: Date?
        for attribute in parts {
            let separator = attribute.firstIndex(of: "=")
            let key = separator.map { String(attribute[attribute.startIndex..<$0]) } ?? attribute
            let attributeValue = separator.map { String(attribute[attribute.index(after: $0)...]) } ?? ""
            switch key.trimmingCharacters(in: .whitespaces).lowercased() {
            case "domain": domain = attributeValue.trimmingCharacters(in: .whitespaces)
            case "path": path = attributeValue.trimmingCharacters(in: .whitespaces)
            case "max-age": maxAge = Int(attributeValue.trimmingCharacters(in: .whitespaces))
            case "expires": expires = SetCookie.parseHttpDate(attributeValue.trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
        self.domain = domain?.isEmpty == false ? domain : nil
        self.path = path?.isEmpty == false ? path : nil
        self.expiresAt = maxAge.map { now.addingTimeInterval(TimeInterval($0)) } ?? expires
    }

    /// RFC 7231 IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`. Obsolete formats are ignored, which
    /// only means such a cookie is treated as a session cookie.
    static func parseHttpDate(_ value: String) -> Date? {
        let fields = value.split(separator: " ").map(String.init)
        guard fields.count == 6, fields[5].uppercased() == "GMT" else { return nil }
        guard let day = Int(fields[1]), let year = Int(fields[3]),
              let month = months.firstIndex(of: fields[2]).map({ $0 + 1 }) else { return nil }
        let time = fields[4].split(separator: ":").map(String.init)
        guard time.count == 3, let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]) else {
            return nil
        }
        let padded = String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
        return ProtocolTimestamp.parse(padded)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
