// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A private, per-namespace file store with explicit byte/entry limits. Automatic LRU eviction is
/// limited to `StorageRoot.cache`, where entries are disposable; durable roots fail before deleting
/// existing data. The store never resolves caller paths outside its namespace.
public actor QuotaFileStore {
    private let namespaceDirectory: URL
    private let root: StorageRoot
    private let quota: StorageQuota
    private let clock: @Sendable () -> Date
    private var lastAccess: Date

    public init(
        roots: StorageRoots,
        root: StorageRoot,
        namespace: String,
        quota: StorageQuota,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard isSinglePathSegment(namespace) else { throw StorageError.invalidNamespace }
        let rootDirectory = roots.directory(root).resolvingSymlinksInPath()
        let directory = rootDirectory.appendingPathComponent(namespace, isDirectory: true)
        try StorageRoots.createDirectory(at: directory)
        let resolved = directory.resolvingSymlinksInPath()
        self.namespaceDirectory = resolved
        self.root = root
        self.quota = quota
        self.clock = clock
        self.lastAccess = Self.scan(resolved).map(\.modifiedAt).max() ?? Date(timeIntervalSince1970: 0)
    }

    public func write(_ relativePath: String, bytes: Data) throws -> StoredFile {
        guard Int64(bytes.count) <= quota.maximumBytes else { throw StorageError.quotaExceeded }
        let target = try resolve(relativePath)
        let parent = target.deletingLastPathComponent()
        try StorageRoots.createDirectory(at: parent)
        guard isDescendant(namespaceDirectory, parent.resolvingSymlinksInPath()) else {
            throw StorageError.invalidPath
        }
        let temporary = parent.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try bytes.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw StorageError.unavailable
        }
        try touch(temporary)
        try reserveCapacity(for: target, temporary: temporary, byteCount: Int64(bytes.count))
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            throw StorageError.unavailable
        }
        return StoredFile(relativePath: relativePath, byteCount: Int64(bytes.count))
    }

    public func read(_ relativePath: String) throws -> Data? {
        let target = try resolve(relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard isDescendant(namespaceDirectory, target.resolvingSymlinksInPath()) else {
            throw StorageError.invalidPath
        }
        guard let bytes = try? Data(contentsOf: target) else { throw StorageError.unavailable }
        try touch(target)
        return bytes
    }

    @discardableResult
    public func delete(_ relativePath: String) throws -> Bool {
        let target = try resolve(relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            return false
        }
        return true
    }

    @discardableResult
    public func clear() -> CleanupResult {
        var removedBytes: Int64 = 0
        var removedEntries = 0
        for entry in Self.scan(namespaceDirectory) where (try? FileManager.default.removeItem(at: entry.url)) != nil {
            removedBytes += entry.byteCount
            removedEntries += 1
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: namespaceDirectory,
            includingPropertiesForKeys: nil
        ) {
            for child in children { try? FileManager.default.removeItem(at: child) }
        }
        let remaining = Self.scan(namespaceDirectory)
        return CleanupResult(
            removedEntries: removedEntries,
            removedBytes: removedBytes,
            remainingEntries: remaining.count,
            remainingBytes: remaining.reduce(Int64(0)) { $0 + $1.byteCount }
        )
    }

    /// Automatically evicts LRU entries only from cache storage. Durable roots are diagnostic-only.
    @discardableResult
    public func cleanup() -> CleanupResult {
        let entries = Self.scan(namespaceDirectory)
        let bytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard root == .cache else {
            return CleanupResult(
                removedEntries: 0,
                removedBytes: 0,
                remainingEntries: entries.count,
                remainingBytes: bytes
            )
        }
        return evict(entries, remainingBytes: bytes, remainingEntries: entries.count)
    }

    public func entries() -> [StoredFile] {
        Self.scan(namespaceDirectory)
            .sorted { $0.relativePath < $1.relativePath }
            .map { StoredFile(relativePath: $0.relativePath, byteCount: $0.byteCount) }
    }

    /// Exposed for diagnostics and tests only; callers must not construct paths below this directory.
    public nonisolated var directory: URL { namespaceDirectory }

    /// Reserves capacity for a replacement before it becomes visible, so the previous target stays
    /// intact when undeletable entries would prevent the resulting store from fitting.
    private func reserveCapacity(for target: URL, temporary: URL, byteCount: Int64) throws {
        let entries = Self.scan(namespaceDirectory).filter { entry in
            entry.url.path != target.path && entry.url.path != temporary.path
        }
        let bytes = entries.reduce(Int64(0)) { $0 + $1.byteCount } + byteCount
        let count = entries.count + 1
        if bytes <= quota.maximumBytes && count <= quota.maximumEntries { return }
        guard root == .cache else { throw StorageError.quotaExceeded }
        let result = evict(entries, remainingBytes: bytes, remainingEntries: count)
        if result.remainingBytes > quota.maximumBytes || result.remainingEntries > quota.maximumEntries {
            throw StorageError.quotaExceeded
        }
    }

    private func evict(_ entries: [Entry], remainingBytes: Int64, remainingEntries: Int) -> CleanupResult {
        var currentBytes = remainingBytes
        var currentEntries = remainingEntries
        var removedBytes: Int64 = 0
        var removedEntries = 0
        let ordered = entries.sorted { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt ? lhs.relativePath < rhs.relativePath : lhs.modifiedAt < rhs.modifiedAt
        }
        for entry in ordered {
            if currentBytes <= quota.maximumBytes && currentEntries <= quota.maximumEntries { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            currentBytes -= entry.byteCount
            currentEntries -= 1
            removedBytes += entry.byteCount
            removedEntries += 1
        }
        return CleanupResult(
            removedEntries: removedEntries,
            removedBytes: removedBytes,
            remainingEntries: currentEntries,
            remainingBytes: currentBytes
        )
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard isSafeRelativePath(relativePath) else { throw StorageError.invalidPath }
        let target = namespaceDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard isDescendant(namespaceDirectory, target) else { throw StorageError.invalidPath }
        return target
    }

    private func touch(_ url: URL) throws {
        lastAccess = max(lastAccess.addingTimeInterval(0.001), clock())
        do {
            try FileManager.default.setAttributes([.modificationDate: lastAccess], ofItemAtPath: url.path)
        } catch {
            throw StorageError.unavailable
        }
    }

    private struct Entry {
        let url: URL
        let relativePath: String
        let byteCount: Int64
        let modifiedAt: Date
    }

    private static func scan(_ directory: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }
        var entries: [Entry] = []
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(prefix) else { continue }
            entries.append(
                Entry(
                    url: url,
                    relativePath: String(resolved.path.dropFirst(prefix.count)),
                    byteCount: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                )
            )
        }
        return entries
    }
}

func isDescendant(_ parent: URL, _ candidate: URL) -> Bool {
    let parentPath = parent.path.hasSuffix("/") ? String(parent.path.dropLast()) : parent.path
    return candidate.path == parentPath || candidate.path.hasPrefix(parentPath + "/")
}
