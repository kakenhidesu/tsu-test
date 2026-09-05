// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

struct ParsedHxpManifest {
    let manifest: HxpManifest
    let canonicalBytes: Data
}

enum HxpManifestParser {
    static let maximumManifestBytes = 128 * 1024
    static let manifestFile = "manifest.json"
    static let signatureFile = "signature.ed25519"

    static func parse(_ bytes: Data, hostApiVersion: SemanticVersion) throws -> ParsedHxpManifest {
        guard bytes.count <= maximumManifestBytes else { throw HxpVerificationError.invalidManifest }
        guard String(data: bytes, encoding: .utf8) != nil else { throw HxpVerificationError.invalidManifest }
        guard let parsed = try? JSONValue.decode(bytes), let root = parsed.objectValue else {
            throw HxpVerificationError.invalidManifest
        }
        guard let canonicalBytes = try? Rfc8785.canonicalize(parsed) else {
            throw HxpVerificationError.invalidManifest
        }
        try requireKeys(
            root,
            required: [
                "format", "manifestVersion", "id", "version", "display", "hostApi", "entry",
                "integrity", "signing", "capabilities", "resourceLimits", "update"
            ]
        )
        guard root.string("format") == "tsuyomi-hxp", root.int("manifestVersion") == 1 else {
            throw HxpVerificationError.invalidManifest
        }
        guard let sourceId = try? SourceId(try text(root, "id")) else {
            throw HxpVerificationError.invalidManifest
        }
        let version = try SemanticVersion(try text(root, "version"))

        let display = try object(root, "display")
        try requireKeys(display, required: ["name", "summary"], optional: ["homepage"])
        let displayName = try bounded(try text(display, "name"), 1, 128)
        let summary = try bounded(try text(display, "summary"), 1, 512)
        let homepage = try display.string("homepage").map { try bounded($0, 1, 4_096) }

        let hostApi = try object(root, "hostApi")
        try requireKeys(hostApi, required: ["minInclusive", "maxExclusive"])
        let hostMin = try SemanticVersion(try text(hostApi, "minInclusive"))
        let hostMax = try SemanticVersion(try text(hostApi, "maxExclusive"))
        guard hostMin < hostMax, hostApiVersion >= hostMin, hostApiVersion < hostMax else {
            throw HxpVerificationError.hostApiIncompatible
        }

        let entry = try text(root, "entry")
        guard ZipReader.isSafeArchivePath(entry), entry.hasSuffix(".mjs"), entry.utf16.count <= 512 else {
            throw HxpVerificationError.invalidManifest
        }

        let integrity = try object(root, "integrity")
        try requireKeys(integrity, required: ["algorithm", "contentDigest", "files"])
        guard integrity.string("algorithm") == "sha256" else { throw HxpVerificationError.invalidManifest }
        let contentDigest = try text(integrity, "contentDigest")
        guard Grammar.isSha256(contentDigest) else { throw HxpVerificationError.invalidManifest }
        guard let filesObject = integrity.object("files"), !filesObject.isEmpty else {
            throw HxpVerificationError.invalidManifest
        }
        var files: [String: String] = [:]
        for (path, digest) in filesObject {
            guard ZipReader.isSafeArchivePath(path), path != manifestFile, path != signatureFile,
                  let digestText = digest.stringValue, Grammar.isSha256(digestText) else {
                throw HxpVerificationError.invalidManifest
            }
            files[path] = digestText
        }
        guard files[entry] != nil else { throw HxpVerificationError.invalidManifest }

        let signing = try object(root, "signing")
        try requireKeys(signing, required: ["algorithm", "keyId", "signatureFile"])
        guard signing.string("algorithm") == "Ed25519", signing.string("signatureFile") == signatureFile else {
            throw HxpVerificationError.invalidManifest
        }
        let keyId = try text(signing, "keyId")
        guard Grammar.isToken(keyId, limit: 128), (8...128).contains(keyId.unicodeScalars.count) else {
            throw HxpVerificationError.invalidManifest
        }

        let capabilities = try HxpCapabilityParser.parse(try object(root, "capabilities"))
        let limits = try object(root, "resourceLimits")
        try requireKeys(limits, required: ["maxExecutionWallTimeMs", "maxMemoryBytes"])
        let resourceLimits = HxpResourceLimits(
            maximumExecutionWallTimeMs: try integer(limits, "maxExecutionWallTimeMs", 100, 30_000),
            maximumMemoryBytes: try integer(limits, "maxMemoryBytes", 1_048_576, 67_108_864)
        )
        let update = try object(root, "update")
        try requireKeys(update, required: ["channel"])
        let channel = try text(update, "channel")
        guard channel == "stable" || channel == "beta" else { throw HxpVerificationError.invalidManifest }

        return ParsedHxpManifest(
            manifest: HxpManifest(
                sourceId: sourceId,
                version: version,
                displayName: displayName,
                summary: summary,
                homepage: homepage,
                hostApiMinInclusive: hostMin,
                hostApiMaxExclusive: hostMax,
                entry: entry,
                contentDigest: contentDigest,
                files: files,
                publisherKeyId: keyId,
                capabilities: capabilities,
                resourceLimits: resourceLimits,
                updateChannel: channel
            ),
            canonicalBytes: canonicalBytes
        )
    }

    static func requireKeys(
        _ value: [String: JSONValue],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        guard required.isSubset(of: Set(value.keys)),
              value.keys.allSatisfy({ required.contains($0) || optional.contains($0) }) else {
            throw HxpVerificationError.invalidManifest
        }
    }

    static func object(_ value: [String: JSONValue], _ name: String) throws -> [String: JSONValue] {
        guard let child = value.object(name) else { throw HxpVerificationError.invalidManifest }
        return child
    }

    static func array(_ value: [String: JSONValue], _ name: String) throws -> [JSONValue] {
        guard let child = value.array(name) else { throw HxpVerificationError.invalidManifest }
        return child
    }

    static func text(_ value: [String: JSONValue], _ name: String) throws -> String {
        guard let child = value.string(name) else { throw HxpVerificationError.invalidManifest }
        return child
    }

    static func flag(_ value: [String: JSONValue], _ name: String) throws -> Bool {
        guard let child = value.bool(name) else { throw HxpVerificationError.invalidManifest }
        return child
    }

    static func integer(_ value: [String: JSONValue], _ name: String, _ minimum: Int, _ maximum: Int) throws -> Int {
        guard let child = value[name], child.stringValue == nil, let number = child.intValue,
              (minimum...maximum).contains(number) else {
            throw HxpVerificationError.invalidManifest
        }
        return number
    }

    static func bounded(_ value: String, _ minimum: Int, _ maximum: Int) throws -> String {
        guard (minimum...maximum).contains(Grammar.codePointCount(value)) else {
            throw HxpVerificationError.invalidManifest
        }
        return value
    }

    static func isPolicyPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("?") && !value.contains("#") && value.utf16.count <= 1_024
    }

    static func originSet(
        _ value: [String: JSONValue],
        _ name: String,
        requireNonEmpty: Bool = false
    ) throws -> Set<HttpsOrigin> {
        let items = try array(value, name)
        if requireNonEmpty, items.isEmpty { throw HxpVerificationError.invalidManifest }
        var origins = Set<HttpsOrigin>()
        for item in items {
            guard let raw = item.stringValue, let origin = try? HttpsOrigin(raw) else {
                throw HxpVerificationError.invalidManifest
            }
            guard origins.insert(origin).inserted else { throw HxpVerificationError.invalidManifest }
        }
        return origins
    }
}
