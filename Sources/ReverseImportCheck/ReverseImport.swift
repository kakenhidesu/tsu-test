// SPDX-License-Identifier: AGPL-3.0-only

// Temporary: proves SwiftPM refuses an import the dependency graph does not allow. This target
// declares no dependencies, so importing a host module must fail to compile. Deleted once observed.
import TsuyomiCore

enum ReverseImport {
    static let shouldNotCompile = StorageRoot.cache
}
