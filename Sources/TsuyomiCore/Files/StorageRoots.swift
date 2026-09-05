// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum StorageRoot: String, Sendable, CaseIterable {
    case extensions
    case cache
    case credentials
    case media
}

public struct StorageQuota: Hashable, Sendable {
    public let maximumBytes: Int64
    public let maximumEntries: Int

    public init(maximumBytes: Int64, maximumEntries: Int) {
        precondition(maximumBytes > 0, "Byte quota must be positive")
        precondition(maximumEntries > 0, "Entry quota must be positive")
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
    }
}

public struct StoredFile: Hashable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
}

public struct CleanupResult: Hashable, Sendable {
    public let removedEntries: Int
    public let removedBytes: Int64
    public let remainingEntries: Int
    public let remainingBytes: Int64
}

public enum StorageError: Error, Equatable, Sendable {
    case invalidNamespace
    case invalidPath
    case unavailable
    case quotaExceeded
}

/// Explicit roots keep durable private state out of device backups and iCloud. Everything the host
/// writes lives under one application-support namespace; nothing is written to Documents.
public struct StorageRoots: Sendable {
    public let base: URL

    public init(base: URL) throws {
        self.base = base
        for root in StorageRoot.allCases {
            let directory = base.appendingPathComponent(root.rawValue, isDirectory: true)
            try StorageRoots.createDirectory(at: directory)
            if root != .media { try StorageRoots.excludeFromBackup(directory) }
        }
    }

    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> StorageRoots {
        let container = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try StorageRoots(base: container.appendingPathComponent("org.tsuyomi", isDirectory: true))
    }

    public func directory(_ root: StorageRoot) -> URL {
        base.appendingPathComponent(root.rawValue, isDirectory: true)
    }

    static func createDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            throw StorageError.unavailable
        }
    }

    static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            throw StorageError.unavailable
        }
    }
}

/// `..`, absolute paths, and empty segments never reach the file system.
func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, path.contains(where: { !$0.isWhitespace }), !path.hasPrefix("/") else { return false }
    let segments = path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
    return segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

func isSinglePathSegment(_ value: String) -> Bool {
    isSafeRelativePath(value) && !value.contains("/") && !value.contains("\\")
}
