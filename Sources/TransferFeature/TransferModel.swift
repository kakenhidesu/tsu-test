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
/// apply, then a report. Nothing reaches the database before the reader has seen the preview.
@MainActor
public final class TransferModel: ObservableObject {
    @Published public private(set) var stage: TransferStage = .idle
    @Published public private(set) var plan: ImportPlan?
    @Published public private(set) var report: TransferReport?
    @Published public private(set) var failureCode: String?
    @Published public private(set) var exportedFile: URL?
    @Published public private(set) var isBusy = false

    private let transfers: TransferRepository
    private let preferences: AppPreferences
    private let roots: StorageRoots
    private let clock: () -> Date
    private var planDigest: String?

    public init(
        transfers: TransferRepository,
        preferences: AppPreferences,
        roots: StorageRoots,
        clock: @escaping () -> Date = Date.init
    ) {
        self.transfers = transfers
        self.preferences = preferences
        self.roots = roots
        self.clock = clock
    }

    public func export() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        do {
            let snapshot = try await transfers.exportSnapshot(
                createdAt: clock(),
                readerPreferences: preferences.portableReader
            )
            let bytes = try TransferCodec.encode(snapshot)
            let url = roots.directory(.cache).appendingPathComponent("tsuyomi-transfer.json")
            try bytes.write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            failureCode = SafeErrorCode.of(error)
        }
    }

    /// The format is decided by the file's own content, so a Hikari backup and a Tsuyomi transfer are
    /// never told apart by whatever name the picker returned.
    public func preview(_ bytes: Data) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failureCode = nil
        report = nil
        switch TransferCodec.parse(bytes) {
        case .fatal(let safeCode):
            plan = nil
            planDigest = nil
            stage = .idle
            failureCode = safeCode
        case .ready(let parsed, let digest):
            do {
                plan = try await transfers.withDatabaseConflicts(parsed)
                planDigest = digest
                stage = .previewing
            } catch {
                plan = nil
                planDigest = nil
                stage = .idle
                failureCode = SafeErrorCode.of(error)
            }
        }
    }

    public func apply() async {
        guard let plan, let planDigest, stage == .previewing, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        stage = .applying
        let session = UUID().uuidString
        do {
            try await transfers.prepare(
                sessionId: session,
                plan: plan,
                planDigest: planDigest,
                normalizedPlanPath: "import/\(planDigest).json",
                preferencePatchJson: String(
                    data: try ImportPlanCodec.encode(plan),
                    encoding: .utf8
                ) ?? "{}",
                startedAt: clock()
            )
            try await transfers.applyPlan(sessionId: session, digest: planDigest, plan: plan)
            preferences.applyImported(plan.readerPreferences, digest: planDigest)
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
            self.plan = nil
            self.planDigest = nil
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
        failureCode = nil
        stage = .idle
    }
}
