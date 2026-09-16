// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

public struct ExcludedBook: Hashable, Sendable, Identifiable {
    public let identity: BookIdentity
    public let title: String

    public var id: BookIdentity { identity }
}

/// The update policy and the two exclusion lists. A change to the policy is written first and the
/// scheduler told afterwards; an exclusion removes neither the book, its progress nor its source.
@MainActor
public final class UpdateSettingsModel: ObservableObject {
    @Published public private(set) var policy = UpdatePolicy()
    @Published public private(set) var excludedBooks: [ExcludedBook] = []
    @Published public private(set) var sources: [InstalledSource] = []
    @Published public private(set) var excludedSourceIds: Set<String> = []

    private let updates: UpdateStore
    private let library: LibraryRepository
    private let registry: SourceRegistry
    private let policyChanged: () async -> Void

    public init(
        updates: UpdateStore,
        library: LibraryRepository,
        registry: SourceRegistry,
        policyChanged: @escaping () async -> Void
    ) {
        self.updates = updates
        self.library = library
        self.registry = registry
        self.policyChanged = policyChanged
    }

    public func load() async {
        policy = (try? await updates.policy()) ?? UpdatePolicy()
        var books: [ExcludedBook] = []
        for identity in (try? await updates.excludedBooks()) ?? [] {
            let title = (try? await library.book(identity))?.title ?? identity.remoteBookId
            books.append(ExcludedBook(identity: identity, title: title))
        }
        excludedBooks = books
        sources = (try? await registry.installedSources()) ?? []
        excludedSourceIds = Set((try? await updates.excludedSources()) ?? [])
    }

    public func setCadence(_ cadence: UpdateCadence) async {
        await save(UpdatePolicy(
            cadence: cadence, unmeteredOnly: policy.unmeteredOnly,
            requiresCharging: policy.requiresCharging, batteryNotLow: policy.batteryNotLow
        ))
    }

    public func setUnmeteredOnly(_ value: Bool) async {
        await save(UpdatePolicy(
            cadence: policy.cadence, unmeteredOnly: value,
            requiresCharging: policy.requiresCharging, batteryNotLow: policy.batteryNotLow
        ))
    }

    public func setRequiresCharging(_ value: Bool) async {
        await save(UpdatePolicy(
            cadence: policy.cadence, unmeteredOnly: policy.unmeteredOnly,
            requiresCharging: value, batteryNotLow: policy.batteryNotLow
        ))
    }

    public func setBatteryNotLow(_ value: Bool) async {
        await save(UpdatePolicy(
            cadence: policy.cadence, unmeteredOnly: policy.unmeteredOnly,
            requiresCharging: policy.requiresCharging, batteryNotLow: value
        ))
    }

    public func setSourceExcluded(_ sourceId: String, excluded: Bool) async {
        try? await updates.setSourceExcluded(sourceId, excluded: excluded)
        await load()
    }

    public func includeBook(_ identity: BookIdentity) async {
        try? await updates.setBookExcluded(identity, excluded: false)
        await load()
    }

    private func save(_ updated: UpdatePolicy) async {
        try? await updates.savePolicy(updated)
        policy = (try? await updates.policy()) ?? updated
        await policyChanged()
    }
}
