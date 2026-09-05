// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// Converts the JSON an extension returns into strict protocol values. Anything that does not
/// validate becomes a typed `SourceException`; no partially trusted value reaches the host.
enum SourceExtensionMarshalling {
    static func failure(
        _ code: SourceErrorCode,
        _ stage: String,
        _ safeCode: String,
        correlationId: String = UUID().uuidString
    ) -> any Error {
        guard let diagnostic = try? SourceDiagnostic(
            correlationId: correlationId,
            stage: String(stage.prefix(64)),
            safeCode: String(safeCode.prefix(128))
        ) else {
            return ProtocolError.invalidDiagnostic
        }
        return SourceException(code: code, diagnostic: diagnostic)
    }

    static func mapNetworkError(_ error: HostNetworkError) -> SourceErrorCode {
        switch error {
        case .timeout: return .networkTimeout
        case .offline, .offlineMiss: return .networkOffline
        case .redirectDisallowed, .redirectLimit: return .networkRedirectDisallowed
        case .responseLimit: return .networkResponseTooLarge
        case .disallowedOrigin: return .originNotGranted
        default: return .extensionRuntimeFailure
        }
    }

    static func request(_ value: [String: JSONValue], offlineOnly: Bool) throws -> SourceNetworkRequest {
        guard let baseUrl = value.string("url") else { throw ProtocolError.invalidRequestUrl }
        var query: [(String, String)]?
        if let raw = value["query"], raw != .null {
            guard let items = raw.arrayValue else { throw ProtocolError.invalidRequestUrl }
            query = try items.map { item in
                guard let object = item.objectValue, let name = object.string("name"),
                      let itemValue = object.string("value") else {
                    throw ProtocolError.invalidRequestUrl
                }
                return (name, itemValue)
            }
        }
        let queryEncoding = value.string("queryEncoding").flatMap(DecodeMode.init(rawValue:))
        guard (query == nil) == (queryEncoding == nil) else { throw ProtocolError.invalidRequestUrl }
        let url: String
        if let query, let queryEncoding {
            url = try encodeUrlQuery(baseUrl, query, queryEncoding)
        } else {
            url = baseUrl
        }
        guard let method = value.string("method").flatMap(NetworkMethod.init(rawValue:)),
              let decode = value.string("decode").flatMap(DecodeMode.init(rawValue:)),
              let cache = value.string("cache").flatMap(NetworkCacheMode.init(rawValue:)) else {
            throw ProtocolError.invalidRequestUrl
        }
        var headers: [String: String] = [:]
        if let raw = value.object("headers") {
            for (name, item) in raw {
                guard let text = item.stringValue else { throw ProtocolError.invalidRequestUrl }
                headers[name] = text
            }
        }
        var form: [String: String]?
        if let raw = value["form"], raw != .null {
            guard let object = raw.objectValue else { throw ProtocolError.invalidRequestUrl }
            var mapped: [String: String] = [:]
            for (name, item) in object {
                guard let text = item.stringValue else { throw ProtocolError.invalidRequestUrl }
                mapped[name] = text
            }
            form = mapped
        }
        return try SourceNetworkRequest(
            url: url,
            method: method,
            headers: headers,
            form: form,
            utf8Body: value.string("utf8Body"),
            decode: decode,
            cache: offlineOnly ? .offlineOnly : cache,
            semanticCacheKey: value.string("semanticCacheKey"),
            referrerUrl: value.string("referrerUrl")
        )
    }

    /// Percent-encodes a structured query in the source's own charset. The extension never builds
    /// the query string itself, so it cannot smuggle a separator through a parameter value.
    static func encodeUrlQuery(
        _ baseUrl: String,
        _ query: [(String, String)],
        _ encoding: DecodeMode
    ) throws -> String {
        guard !query.isEmpty, query.count <= 64 else { throw ProtocolError.invalidRequestUrl }
        guard var components = URLComponents(string: baseUrl),
              components.percentEncodedQuery == nil, components.fragment == nil else {
            throw ProtocolError.invalidRequestUrl
        }
        let charset: String.Encoding
        switch encoding {
        case .auto:
            throw ProtocolError.invalidRequestUrl
        case .utf8:
            charset = .utf8
        case .gb18030:
            charset = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case .big5hkscs:
            charset = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
                )
            )
        }
        var encoded: [String] = []
        for (name, value) in query {
            guard !name.isEmpty, name.utf16.count <= 256, value.utf16.count <= 2_048 else {
                throw ProtocolError.invalidRequestUrl
            }
            guard let encodedName = percentEncode(name, charset), let encodedValue = percentEncode(value, charset)
            else { throw ProtocolError.invalidRequestUrl }
            encoded.append("\(encodedName)=\(encodedValue)")
        }
        components.percentEncodedQuery = encoded.joined(separator: "&")
        guard let url = components.string else { throw ProtocolError.invalidRequestUrl }
        return url
    }

    /// `application/x-www-form-urlencoded` percent-encoding over the source charset's bytes.
    private static func percentEncode(_ value: String, _ charset: String.Encoding) -> String? {
        guard let bytes = value.data(using: charset) else { return nil }
        var output = ""
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                output.append(Character(Unicode.Scalar(byte)))
            case UInt8(ascii: " "):
                output.append("+")
            default:
                output.append(String(format: "%%%02X", byte))
            }
        }
        return output
    }

    static func summaries(_ root: [String: JSONValue], stage: String) throws -> [SourceBookSummary] {
        guard let items = root.array("items") else {
            throw failure(.malformedSourceResponse, stage, "missing-items")
        }
        return try items.map { item in
            guard let object = item.objectValue else {
                throw failure(.malformedSourceResponse, stage, "invalid-item")
            }
            return try summary(object)
        }
    }

    static func summary(_ value: [String: JSONValue]) throws -> SourceBookSummary {
        guard let sourceId = value.string("sourceId"), let remoteBookId = value.string("remoteBookId"),
              let title = value.string("title"), let canonicalUrl = value.string("canonicalUrl") else {
            throw ProtocolError.invalidBookTitle
        }
        return try SourceBookSummary(
            identity: try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId),
            title: title,
            author: value.string("author"),
            coverUrl: value.string("coverUrl"),
            canonicalUrl: canonicalUrl
        )
    }

    static func detail(_ value: [String: JSONValue]) throws -> SourceBookDetail {
        guard let summaryObject = value.object("summary"), let tags = value.array("tags") else {
            throw ProtocolError.invalidTags
        }
        return try SourceBookDetail(
            summary: try summary(summaryObject),
            description: value.string("description"),
            tags: tags.compactMap(\.stringValue),
            status: value.string("status")
        )
    }

    static func directory(_ value: [String: JSONValue]) throws -> SourceDirectory {
        guard let sourceId = value.string("sourceId"), let remoteBookId = value.string("remoteBookId"),
              let chapters = value.array("chapters") else {
            throw ProtocolError.emptyDirectory
        }
        return try SourceDirectory(
            bookIdentity: try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId),
            chapters: try chapters.map { element in
                guard let chapter = element.objectValue, let chapterId = chapter.string("chapterId"),
                      let title = chapter.string("title"), let url = chapter.string("url") else {
                    throw ProtocolError.invalidChapterId
                }
                return try SourceChapter(
                    chapterId: chapterId,
                    title: title,
                    url: url,
                    volumeTitle: chapter.string("volumeTitle")
                )
            }
        )
    }

    static func remoteLibraryPage(_ root: [String: JSONValue]) throws -> RemoteLibraryPage {
        guard let complete = root.bool("complete") else {
            throw failure(.malformedSourceResponse, "remote-library-read-parse", "missing-complete")
        }
        let items = try summaries(root, stage: "remote-library-read-parse")
        do {
            return try RemoteLibraryPage(items: items, nextCursor: root.string("nextCursor"), complete: complete)
        } catch {
            throw failure(.malformedSourceResponse, "remote-library-read-parse", "invalid-page")
        }
    }

    static func remoteAddResult(
        _ root: [String: JSONValue],
        expectedSourceId: String,
        expectedRemoteBookId: String
    ) throws -> RemoteLibraryAddResult {
        guard let sourceId = root.string("sourceId"), let remoteBookId = root.string("remoteBookId"),
              sourceId == expectedSourceId, remoteBookId == expectedRemoteBookId else {
            throw failure(.malformedSourceResponse, "remote-library-add-parse", "identity-mismatch")
        }
        let outcome: RemoteLibraryAddOutcome
        switch root.string("outcome") {
        case "applied": outcome = .applied
        case "already-present": outcome = .alreadyPresent
        default: throw failure(.malformedSourceResponse, "remote-library-add-parse", "invalid-outcome")
        }
        return RemoteLibraryAddResult(
            identity: try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId),
            outcome: outcome
        )
    }
}

extension HxpRemoteOperationPolicy {
    func networkPolicy() throws -> RemoteOperationRequestPolicy {
        var fixed: [String: String] = [:]
        var remoteBookIdParameter: String?
        var cursorParameter: String?
        for parameter in parameters {
            switch parameter {
            case .fixed(let name, let value): fixed[name] = value
            case .remoteBookId(let name): remoteBookIdParameter = name
            case .cursor(let name): cursorParameter = name
            }
        }
        return try RemoteOperationRequestPolicy(
            origin: origin,
            method: method,
            path: path,
            fixedParameters: fixed,
            remoteBookIdParameter: remoteBookIdParameter,
            cursorParameter: cursorParameter,
            referrerPath: referrerPath,
            redirects: try redirects.map { redirect in
                try RemoteOperationRedirectPolicy(
                    origin: redirect.origin,
                    method: redirect.method,
                    path: redirect.path,
                    fixedParameters: redirect.parameters,
                    referrerPath: redirect.referrerPath
                )
            }
        )
    }
}
