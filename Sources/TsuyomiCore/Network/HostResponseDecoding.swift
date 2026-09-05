// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Charset resolution and strict decoding for source responses. A byte sequence that is not valid in
/// the resolved charset is a `DECODE` failure, never a lossy replacement-character document.
enum HostResponseDecoding {
    static let utf8Bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func decode(
        _ bytes: Data,
        requested: DecodeMode,
        contentType: String?
    ) throws -> (text: String, mode: DecodeMode) {
        let mode: DecodeMode
        switch requested {
        case .auto:
            mode = charsetFromBom(bytes) ?? charsetFromContentType(contentType) ?? .utf8
        default:
            mode = requested
        }
        let encoding: String.Encoding
        switch mode {
        case .utf8:
            encoding = .utf8
        case .gb18030:
            encoding = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case .big5hkscs:
            encoding = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
                )
            )
        case .auto:
            throw HostNetworkException(.decode)
        }
        var body = bytes
        if mode == .utf8, bytes.starts(with: utf8Bom) {
            body = bytes.dropFirst(utf8Bom.count)
        }
        guard let text = String(data: body, encoding: encoding) else { throw HostNetworkException(.decode) }
        return (text, mode)
    }

    static func charsetFromBom(_ bytes: Data) -> DecodeMode? {
        bytes.starts(with: utf8Bom) ? .utf8 : nil
    }

    static func charsetFromContentType(_ contentType: String?) -> DecodeMode? {
        guard let contentType else { return nil }
        guard let range = contentType.range(of: "charset", options: .caseInsensitive) else { return nil }
        var rest = contentType[range.upperBound...].drop { $0 == " " }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\"" || $0 == "'" }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.lowercased()
        switch name {
        case "utf-8", "utf8": return .utf8
        case "gb18030", "gbk", "gb2312": return .gb18030
        case "big5", "big5-hkscs": return .big5hkscs
        default: return nil
        }
    }

    static let requestHeaderAllowlist: Set<String> = [
        "accept", "accept-language", "if-none-match", "if-modified-since"
    ]
    static let exposedResponseHeaders: Set<String> = ["content-type", "etag", "last-modified"]
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    static let maximumRedirects = 5
    static let maximumBodyBytes = 64 * 1024

    static func allowedHeaders(_ headers: [String: String]) throws -> [String: String] {
        guard headers.count <= 32 else { throw HostNetworkException(.headerDisallowed) }
        var result: [String: String] = [:]
        for (name, value) in headers {
            let normalized = name.lowercased()
            guard !name.unicodeScalars.contains("\u{0}"), !value.unicodeScalars.contains("\u{0}"),
                  requestHeaderAllowlist.contains(normalized) else {
                throw HostNetworkException(.headerDisallowed)
            }
            result[normalized] = value
        }
        return result
    }

    static func requestBody(_ request: SourceNetworkRequest) throws -> Data? {
        guard request.method == .post else { return nil }
        let body: Data
        if let form = request.form {
            body = Data(
                form.keys.sorted()
                    .map { "\(formEncoded($0))=\(formEncoded(form[$0] ?? ""))" }
                    .joined(separator: "&")
                    .utf8
            )
        } else if let utf8Body = request.utf8Body {
            body = Data(utf8Body.utf8)
        } else {
            body = Data()
        }
        guard body.count <= maximumBodyBytes else { throw HostNetworkException(.bodyLimit) }
        return body
    }

    /// `application/x-www-form-urlencoded`: every byte outside the unreserved set is escaped and a
    /// space becomes `+`, so a form value can never inject a separator.
    static func formEncoded(_ value: String) -> String {
        var output = ""
        for byte in Array(value.utf8) {
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
}
