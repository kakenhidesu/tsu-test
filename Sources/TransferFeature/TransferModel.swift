// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public enum TransferStage: Sendable, Equatable {
    case idle
    case previewing
    case applying
    case reported
}

public struct TransferReport: Sendable, Equatable {
    public let summary: ImportSummary
    public let warnings: [ImportWarning]
}

/// Export writes one canonical `tsuyomi-transfer` file; import is always preview, then an explicit
/// apply, then a report. Nothing is written to the database before the reader has seen the preview.
@MainActor
public final class TransferModel: ObservableObject {
    @Published public private(set) var stage: TransferStage = .idle
    @Published public private(set) var plan: ImportPlan?
    @Published public private(set) var report: TransferReport?
    @Published public private(set) var failureCode: String?
    @Published public private(set) var exportedFile: URL?

    private let library: LibraryRepository
    private let collections: CollectionStore
    private let progress: ReadingProgressStore
    private let transfers: TransferRepository
    private let preferences: AppPreferences
    private let roots: StorageRoots
    private let clock: () -> Date
    private var sessionId: String?
    private var planDigest: String?

    public init(
        library: LibraryRepository,
        collections: CollectionStore,
        progress: ReadingProgressStore,
        transfers: TransferRepository,
        preferences: AppPreferences,
        roots: StorageRoots,
        clock: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.collections = collections
        self.progress = progress
        self.transfers = transfers
        self.preferences = preferences
        self.roots = roots
        self.clock = clock
    }

    public func export() async {
        failureCode = nil
        do {
            let snapshot = try await TransferSnapshotBuilder.snapshot(
                library: library,
                collections: collections,
                progress: progress,
                preferences: preferences.reader,
                createdAt: clock()
            )
            let bytes = try TransferCodec.encode(snapshot)
            let url = roots.directory(.cache)
                .appendingPathComponent("tsuyomi-transfer.json")
            try bytes.write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// Parsing chooses the format by its own content, so a Hikari backup and a Tsuyomi transfer are
    /// never told apart by the file name the picker happened to return.
    public func preview(_ bytes: Data) async {
        failureCode = nil
        report = nil
        switch TransferCodec.parse(bytes) {
        case .fatal(let safeCode):
            plan = nil
            stage = .idle
            failureCode = safeCode
        case .ready(let parsed, let digest):
            do {
                let reconciled = try await transfers.withDatabaseConflicts(parsed)
                plan = reconciled
                planDigest = digest
                stage = .previewing
            } catch {
                plan = nil
                stage = .idle
                failureCode = SafeErrorCode.of(error)
            }
        }
    }

    public func apply() async {
        guard let plan, let planDigest, stage == .previewing else { return }
        stage = .applying
        let session = UUID().uuidString
        do {
            try await transfers.prepare(
                sessionId: session,
                plan: plan,
                planDigest: planDigest,
                normalizedPlanPath: "import/\(planDigest).json",
                preferencePatchJson: TransferPreferencePatch.json(plan.readerPreferences),
                startedAt: clock()
            )
            sessionId = session
            try await transfers.applyPlan(sessionId: session, digest: planDigest, plan: plan)
            if let incoming = plan.readerPreferences {
                preferences.setReader(TransferPreferencePatch.merged(preferences.reader, incoming))
            }
            _ = try await transfers.markPreferencesApplied(sessionId: session, digest: planDigest)
            let summary = ImportSummary(
                sessionId: session,
                kind: plan.kind,
                importedBooks: plan.books.count,
                importedShelves: plan.shelves.count,
                warningCount: plan.warnings.count,
                completedAt: clock()
            )
            _ = try await transfers.complete(sessionId: session, digest: planDigest, summary: summary)
            report = TransferReport(
                summary: summary,
                warnings: try await transfers.warnings(sessionId: session)
            )
            stage = .reported
        } catch {
            failureCode = SafeErrorCode.of(error)
            _ = try? await transfers.abort(sessionId: session, digest: planDigest, cleanupPending: true)
            stage = .previewing
        }
    }

    public func discardPreview() {
        plan = nil
        planDigest = nil
        stage = .idle
    }
}
