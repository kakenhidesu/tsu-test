// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One process-wide fence for everything that changes which extension is installed or trusted:
/// install, uninstall, repository changes and a refresh that may revoke. A second mutation while one
/// runs is refused rather than queued, so two screens can never race an archive on disk.
public actor ExtensionMutationGate {
    private var held = false

    public init() {}

    public func withMutation<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard !held else { throw ExtensionInstallError.busy }
        held = true
        defer { held = false }
        return try await body()
    }
}
