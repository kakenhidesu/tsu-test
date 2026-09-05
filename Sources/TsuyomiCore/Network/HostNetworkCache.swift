// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public struct HostNetworkCacheKey: Hashable, Sendable {
    public let sourceId: String
    public let extensionVersion: String
    public let identity: String
    public let decode: DecodeMode

    public init(sourceId: String, extensionVersion: String, identity: String, decode: DecodeMode) {
        self.sourceId = sourceId
        self.extensionVersion = extensionVersion
        self.identity = identity
        self.decode = decode
    }
}

public protocol HostNetworkCache: Sendable {
    func get(_ key: HostNetworkCacheKey) async -> SourceNetworkResponse?
    func put(_ key: HostNetworkCacheKey, response: SourceNetworkResponse) async
}

public actor InMemoryHostNetworkCache: HostNetworkCache {
    private var responses: [HostNetworkCacheKey: SourceNetworkResponse] = [:]

    public init() {}

    public func get(_ key: HostNetworkCacheKey) -> SourceNetworkResponse? { responses[key] }

    public func put(_ key: HostNetworkCacheKey, response: SourceNetworkResponse) { responses[key] = response }
}

/// Private, bounded process-persistent cache. `partition` is an opaque host-owned revision that
/// prevents anonymous or superseded credential responses from satisfying the current session.
public actor FileHostNetworkCache: HostNetworkCache {
    public static let defaultPartition = "anonymous"

    private let files: QuotaFileStore
    private let partition: String

    private static let magic: UInt32 = 0x5453_5943
    private static let formatVersion: UInt32 = 1
    private static let maximumEntryBytes = 17 * 1024 * 1024
    private static let maximumTextBytes = 16 * 1024 * 1024
    private static let maximumIdentityBytes = 8 * 1024
    private static let maximumUrlBytes = 8 * 1024
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumPartitionBytes = 1024
    private static let maximumMetadataBytes = 1024

    public init(files: QuotaFileStore, partition: String = FileHostNetworkCache.defaultPartition) throws {
        guard isNonBlank(partition), partition.utf8.count <= Self.maximumPartitionBytes,
              !partition.unicodeScalars.contains("\u{0}") else {
            throw HostNetworkException(.invalidRequest)
        }
        self.files = files
        self.partition = partition
    }

    public func get(_ key: HostNetworkCacheKey) async -> SourceNetworkResponse? {
        let path = self.path(key)
        guard let bytes = try? await files.read(path), let bytes else { return nil }
        guard let decoded = try? decode(bytes, expected: key) else {
            _ = try? await files.delete(path)
            return nil
        }
        return decoded
    }

    public func put(_ key: HostNetworkCacheKey, response: SourceNetworkResponse) async {
        guard response.text != nil, response.bytes == nil else { return }
        guard let encoded = try? encode(key, response) else { return }
        _ = try? await files.write(path(key), bytes: encoded)
    }

    private func encode(_ key: HostNetworkCacheKey, _ response: SourceNetworkResponse) throws -> Data {
        guard let text = response.text else { throw BinaryDecodeError.malformed }
        var writer = BinaryWriter()
        writer.write(Self.magic)
        writer.write(Self.formatVersion)
        writer.write(text: key.sourceId)
        writer.write(text: key.extensionVersion)
        writer.write(text: key.identity)
        writer.write(text: key.decode.rawValue)
        writer.write(UInt32(response.status))
        writer.write(text: response.finalUrl)
        writer.write(UInt32(response.headers.count))
        for name in response.headers.keys.sorted() {
            writer.write(text: name)
            writer.write(text: response.headers[name] ?? "")
        }
        writer.write(text: text)
        writer.write(text: response.decodeUsed.rawValue)
        writer.write(text: response.diagnosticId)
        return writer.data
    }

    private func decode(_ bytes: Data, expected: HostNetworkCacheKey) throws -> SourceNetworkResponse {
        guard (1...Self.maximumEntryBytes).contains(bytes.count) else { throw BinaryDecodeError.malformed }
        var reader = BinaryReader(bytes)
        guard try reader.readUInt32() == Self.magic, try reader.readUInt32() == Self.formatVersion else {
            throw BinaryDecodeError.malformed
        }
        let sourceId = try reader.readText(maximum: Self.maximumMetadataBytes)
        let extensionVersion = try reader.readText(maximum: Self.maximumMetadataBytes)
        let identity = try reader.readText(maximum: Self.maximumIdentityBytes)
        guard let decodeMode = DecodeMode(rawValue: try reader.readText(maximum: Self.maximumMetadataBytes)) else {
            throw BinaryDecodeError.malformed
        }
        let stored = HostNetworkCacheKey(
            sourceId: sourceId,
            extensionVersion: extensionVersion,
            identity: identity,
            decode: decodeMode
        )
        guard stored == expected else { throw BinaryDecodeError.malformed }
        let status = Int(try reader.readUInt32())
        let finalUrl = try reader.readText(maximum: Self.maximumUrlBytes)
        let headerCount = Int(try reader.readUInt32())
        guard (0...32).contains(headerCount) else { throw BinaryDecodeError.malformed }
        var headers: [String: String] = [:]
        for _ in 0..<headerCount {
            let name = try reader.readText(maximum: Self.maximumMetadataBytes)
            headers[name] = try reader.readText(maximum: Self.maximumHeaderBytes)
        }
        let text = try reader.readText(maximum: Self.maximumTextBytes)
        guard let decodeUsed = DecodeMode(rawValue: try reader.readText(maximum: Self.maximumMetadataBytes)) else {
            throw BinaryDecodeError.malformed
        }
        let diagnosticId = try reader.readText(maximum: Self.maximumMetadataBytes)
        try reader.requireExhausted()
        guard let response = try? SourceNetworkResponse(
            status: status,
            finalUrl: finalUrl,
            headers: headers,
            text: text,
            bytes: nil,
            decodeUsed: decodeUsed,
            cacheState: .fresh,
            diagnosticId: diagnosticId
        ) else { throw BinaryDecodeError.malformed }
        return response
    }

    private func path(_ key: HostNetworkCacheKey) -> String {
        let material = "\(key.sourceId)\u{0}\(key.extensionVersion)\u{0}\(partition)\u{0}"
            + "\(key.identity)\u{0}\(key.decode.rawValue)"
        return "responses/\(Sha256.hex(material)).bin"
    }
}
