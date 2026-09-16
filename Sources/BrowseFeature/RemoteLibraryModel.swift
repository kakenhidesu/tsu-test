// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiRemoteLibrary
import TsuyomiSource
import TsuyomiUI

/// What the mirror page shows: the stored copy of the site's shelf, narrowed to one folder when the
/// page was opened on a folder. Everything here came from the database; nothing was fetched to show it.
public struct RemoteMirrorContent: Sendable {
    public let mirror: RemoteMirror
    public let books: [BookIdentity: LibraryBook]
    public let targetId: String?
    public let grouped: Bool

    public var items: [RemoteMirrorItem] {
        RemoteMirrorTargets.items(in: mirror, targetId: targetId)
    }

    public var defaultTargetId: String? { RemoteMirrorTargets.defaultTargetId(mirror.targets) }

    public var liveTargets: [RemoteMirrorTarget] { mirror.targets.filter { !$0.frozen } }

    public func target(_ targetId: String?) -> RemoteMirrorTarget? {
        mirror.targets.first { $0.targetId == targetId }
    }

    public func book(_ item: RemoteMirrorItem) -> LibraryBook? { books[item.identity] }
}

/// Something the page has to say on top of its content, each with exactly one way out.
public enum RemoteMirrorNotice: Equatable, Sendable {
    case loginRequired
    case verificationRequired
    case cancelled
    case copied(Int)
    case failed(String)
    case mutation(RemoteWriteOperation, RemoteMutationResult)
}

/// A website write the reader asked for and has not yet finished authorising or confirming.
public enum PendingRemoteAction: Equatable, Sendable {
    case remove(BookIdentity)
    case move(BookIdentity, targetId: String, targetName: String)

    public var operation: RemoteWriteOperation {
        switch self {
        case .remove: return .remove
        case .move: return .move
        }
    }

    public var identity: BookIdentity {
        switch self {
        case .remove(let identity), .move(let identity, _, _): return identity
        }
    }
}

/// The site's own shelf, mirrored. Opening the page reads the mirror; only `refresh` talks to the
/// site. Copying is local; moving or removing a book on the site is one authorised write per book.
@MainActor
public final class RemoteLibraryModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<RemoteMirrorContent> = .loading
    @Published public private(set) var notice: RemoteMirrorNotice?
    @Published public private(set) var isBusy = false
    @Published public private(set) var selected: Set<BookIdentity> = []
    @Published public private(set) var pendingCopy: [BookIdentity]?
    @Published public private(set) var pendingAuthorization: PendingRemoteAction?
    @Published public private(set) var pendingRemoveConfirmation: PendingRemoteAction?
    @Published public var layout: LibraryLayoutChoice = .grid

    public let sourceId: SourceId
    public let targetId: String?
    private let coordinator: RemoteLibraryCoordinator
    private let mirror: RemoteMirrorStore
    private let library: LibraryRepository
    private let preferences: AppPreferences
    private let clock: () -> Date

    public init(
        sourceId: SourceId,
        targetId: String? = nil,
        coordinator: RemoteLibraryCoordinator,
        mirror: RemoteMirrorStore,
        library: LibraryRepository,
        preferences: AppPreferences,
        clock: @escaping () -> Date = Date.init
    ) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.coordinator = coordinator
        self.mirror = mirror
        self.library = library
        self.preferences = preferences
        self.clock = clock
    }

    public var isGroupingEnabled: Bool { preferences.library.websiteGrouping(sourceId.value) }

    public var content: RemoteMirrorContent? {
        if case .content(let content) = state { return content }
        return nil
    }

    /// Zero network: the page shows what the last read left behind.
    public func load() async {
        do {
            guard let stored = try await mirror.mirror(sourceId: sourceId.value) else {
                state = .empty(title: "尚未读取网站收藏", detail: "刷新列表会向网站请求你的收藏；除此之外这一页不会联网。")
                return
            }
            var books: [BookIdentity: LibraryBook] = [:]
            for item in stored.items {
                books[item.identity] = try await library.book(item.identity)
            }
            let content = RemoteMirrorContent(
                mirror: stored, books: books, targetId: targetId, grouped: isGroupingEnabled
            )
            if content.items.isEmpty {
                state = .empty(title: "网站收藏是空的", detail: stored.binding.frozen ? "这个来源已休眠。" : nil)
            } else {
                state = .content(content)
            }
            selected = selected.filter { identity in content.items.contains { $0.identity == identity } }
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取网站收藏的本地副本。")
        }
    }

    /// The one network read on this page, and only when the reader asks for it.
    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        notice = nil
        if case .empty = state { state = .loading }
        switch await coordinator.pull(sourceId) {
        case .success:
            await load()
        case .loginRequired:
            await load()
            notice = .loginRequired
        case .verificationRequired:
            await load()
            notice = .verificationRequired
        case .cancelled:
            await load()
            notice = .cancelled
        case .failure(let failure, let code):
            await load()
            notice = .failed(failure == .sourceFailure ? code : failure.rawValue)
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: Presentation

    public var supportsGrouping: Bool {
        guard let content else { return false }
        return RemoteMirrorTargets.supportsGrouping(content.mirror.targets)
    }

    /// Grouping is presentation only: turning it on or off never moves a book anywhere.
    public func setGrouping(_ enabled: Bool) async {
        preferences.setWebsiteGrouping(sourceId.value, enabled: enabled)
        await load()
    }

    public func cycleLayout() {
        layout = layout.next
    }

    public func summary(_ item: RemoteMirrorItem) -> SourceBookSummary? {
        guard let book = content?.book(item) else { return nil }
        return try? SourceBookSummary(
            identity: book.identity,
            title: book.title,
            author: book.author,
            coverUrl: book.coverUrl,
            canonicalUrl: book.canonicalUrl ?? "",
            remoteTargetId: item.targetId
        )
    }

    // MARK: Selection

    public func toggle(_ identity: BookIdentity) {
        if selected.contains(identity) {
            selected.remove(identity)
        } else {
            selected.insert(identity)
        }
    }

    public func selectAll() {
        selected = Set(content?.items.map(\.identity) ?? [])
    }

    public func clearSelection() {
        selected = []
    }

    public var singleSelection: BookIdentity? {
        selected.count == 1 ? selected.first : nil
    }

    // MARK: Copying to the local shelf

    /// `复制到本地书架` is local. The first copy from a source asks once whether the reader understands
    /// that the site is not written; the answer is kept under the source's current capability set.
    public func copySelectedToLibrary() async {
        await requestCopy(Array(selected).sorted())
    }

    public func copyAllToLibrary() async {
        await requestCopy(content?.items.map(\.identity) ?? [])
    }

    public func confirmCopy() async {
        guard let identities = pendingCopy else { return }
        pendingCopy = nil
        try? await coordinator.dismissFirstImportPrompt(sourceId: sourceId)
        await copy(identities)
    }

    public func cancelCopy() {
        pendingCopy = nil
    }

    private func requestCopy(_ identities: [BookIdentity]) async {
        guard !identities.isEmpty, !isBusy else { return }
        if await coordinator.firstImportPromptDismissed(sourceId: sourceId) {
            await copy(identities)
        } else {
            pendingCopy = identities
        }
    }

    private func copy(_ identities: [BookIdentity]) async {
        isBusy = true
        defer { isBusy = false }
        let now = clock()
        var added = 0
        do {
            for identity in identities {
                guard let stored = content?.books[identity] else { continue }
                let book = LibraryBook(
                    identity: stored.identity,
                    title: stored.title,
                    addedAt: now,
                    metadataUpdatedAt: stored.metadataUpdatedAt,
                    authors: stored.authors,
                    coverUrl: stored.coverUrl,
                    canonicalUrl: stored.canonicalUrl,
                    status: stored.status,
                    remoteTags: stored.remoteTags
                )
                if try await library.addToLibrary(book) { added += 1 }
            }
            selected = []
            notice = .copied(added)
        } catch {
            notice = .failed(SafeErrorCode.of(error))
        }
    }

    // MARK: Writing to the site

    /// Removal is offered for exactly one book. It first needs the source's removal consent, then
    /// a confirmation naming the book, then one signed request.
    public func requestRemoveSelected() async {
        guard let identity = singleSelection, !isBusy else { return }
        let action = PendingRemoteAction.remove(identity)
        if await coordinator.writebackEnabled(.remove, sourceId: sourceId) {
            pendingRemoveConfirmation = action
        } else {
            pendingAuthorization = action
        }
    }

    public func requestMoveSelected(to target: RemoteMirrorTarget) async {
        guard let identity = singleSelection, !isBusy else { return }
        let action = PendingRemoteAction.move(identity, targetId: target.targetId, targetName: target.displayName)
        if await coordinator.writebackEnabled(.move, sourceId: sourceId) {
            await perform(action)
        } else {
            pendingAuthorization = action
        }
    }

    /// Consent given in the just-in-time dialog. A removal still goes on to its own confirmation.
    public func authorizePendingAction() async {
        guard let action = pendingAuthorization else { return }
        pendingAuthorization = nil
        do {
            try await coordinator.grantWriteback(action.operation, sourceId: sourceId)
        } catch {
            notice = .failed(SafeErrorCode.of(error))
            return
        }
        switch action {
        case .remove: pendingRemoveConfirmation = action
        case .move: await perform(action)
        }
    }

    public func cancelPendingAction() {
        pendingAuthorization = nil
        pendingRemoveConfirmation = nil
    }

    public func confirmRemove() async {
        guard let action = pendingRemoveConfirmation else { return }
        pendingRemoveConfirmation = nil
        await perform(action)
    }

    private func perform(_ action: PendingRemoteAction) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let result: RemoteMutationResult
        switch action {
        case .remove(let identity):
            result = await coordinator.remove(identity)
        case .move(let identity, let targetId, let targetName):
            result = await coordinator.move(identity, targetId: targetId, targetName: targetName)
        }
        if case .consentRequired = result {
            pendingAuthorization = action
            return
        }
        selected = []
        await load()
        notice = .mutation(action.operation, result)
    }
}

/// The three densities a shelf can be shown at, cycled by one action.
public enum LibraryLayoutChoice: String, Sendable, CaseIterable {
    case grid
    case list
    case compact

    public var next: LibraryLayoutChoice {
        switch self {
        case .grid: return .list
        case .list: return .compact
        case .compact: return .grid
        }
    }
}
