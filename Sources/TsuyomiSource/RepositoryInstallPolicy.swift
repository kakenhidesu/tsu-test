// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The checks that decide whether a package listed in an index may become the archive this host
/// installs. They are one function because the index is only a hint: the manifest inside the
/// downloaded archive is what actually grants anything, and every way the two can disagree has to be
/// refused in the same place.
public enum RepositoryInstallPolicy {
    public static func requireInstallable(
        listed: RepositoryPackage,
        manifest: HxpManifest,
        archiveBytes: Data,
        hostApi: SemanticVersion,
        activeVersion: SemanticVersion?
    ) throws {
        guard archiveBytes.count == listed.sizeBytes,
              Sha256.hex(archiveBytes) == listed.sha256 else {
            throw RepositoryError.packageDigestMismatch
        }
        guard manifest.sourceId == listed.id, manifest.version == listed.version else {
            throw RepositoryError.indexManifestMismatch
        }
        guard manifest.capabilities == listed.capabilities else {
            throw RepositoryError.indexManifestMismatch
        }
        guard manifest.hostApiMinInclusive == listed.hostApiMinInclusive,
              manifest.hostApiMaxExclusive == listed.hostApiMaxExclusive else {
            throw RepositoryError.indexManifestMismatch
        }
        guard hostApi >= manifest.hostApiMinInclusive, hostApi < manifest.hostApiMaxExclusive else {
            throw RepositoryError.hostApiIncompatible
        }
        if let activeVersion, manifest.version <= activeVersion {
            throw RepositoryError.downgradeRejected
        }
    }
}
