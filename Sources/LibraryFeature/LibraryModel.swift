// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI
import TsuyomiUpdates

public struct LibraryContent: Sendable {
    public let entries: [LibraryEntry]
}

public enum LibrarySelectionKind: Sendable, Equatable {
    case books
    case collections
}

/// The shelf is entirely local. Nothing here talks to a source: removing a book, moving it into a
/// collection, or reordering the shelf are all writes to this device only.
@MainActor
public final class LibraryModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<LibraryContent> = .loading
    @Published public var filter: SystemLibraryFilter = .all
    @Published public private(set) var tab: LibraryTab = .all
    @Published public var layout: LibraryLayout = .grid {
        didSet { persistPresentation() }
    }
    @Published public var sort: LibrarySortMode = .smart {
        didSet { persistPresentation() }
    }
    @Published public var sortDescending = false {
        didSet { persistPresentation() }
    }
    @Published public private(set) var mirrors: [RemoteMirrorBinding] = []
    @Published public private(set) var selectionKind: LibrarySelectionKind?
    @Published public private(set) var selectedBooks: Set<BookIdentity> = []
    @Published public private(set) var selectedCollections: Set<String> = []
    @Published public private(set) var hiddenSystemNodes: Set<SystemLibraryFilter> = []
    @Published public private(set) var activeCollection: LibraryCollection?
    @Published public var isShortcutBarCollapsed = false
    @Published public private(set) var isArranging = false
    /// The inbox: every detected update not yet read through or ignored, by book.
    @Published public private(set) var unresolvedUpdates: [BookIdentity: UnresolvedUpdate] = [:]
    @Published public private(set) var updateSession: UpdateSessionSummary?
    @Published public private(set) var isCheckingUpdates = false
    @Published public private(set) var undoIgnoreToken: String?
    @Published public private(set) var showUpdatesOnly = false
    @Published public private(set) var dismissedSessionId: String?

    private let library: LibraryRepository
    private let collections: CollectionStore
    private let preferences: AppPreferences
    private let mirrorStore: RemoteMirrorStore?
    private let updates: UpdateStore?
    private let checker: UpdateCoordinator?
    private let clock: () -> Date
    private var entries: [LibraryEntry] = []
    private var allCollections: [LibraryCollection] = []
    private var restoringPresentation = false

    public init(
        library: LibraryRepository,
        collections: CollectionStore,
        preferences: AppPreferences,
        mirrors mirrorStore: RemoteMirrorStore? = nil,
        updates: UpdateStore? = nil,
        checker: UpdateCoordinator? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.collections = collections
        self.preferences = preferences
        self.mirrorStore = mirrorStore
        self.updates = updates
        self.checker = checker
        self.clock = clock
        hiddenSystemNodes = Set(
            preferences.library.hiddenSystemNodes.compactMap(SystemLibraryFilter.init(rawValue:))
        )
        showUpdatesOnly = preferences.library.showUpdatesOnly
        restorePresentation(for: .all)
    }

    /// The updates-only filter applies at the root of the 书架 tab and nowhere else; the other tabs
    /// keep the value without exposing it.
    public func project(_ values: [LibraryEntry]) -> [LibraryEntry] {
        let projected = LibraryProjection.apply(
            values, filter: filter, sort: sort, descending: sortDescending, updates: unresolvedUpdates
        )
        guard showUpdatesOnly, filter == .all, activeCollection == nil else { return projected }
        return projected.filter { unresolvedUpdates[$0.book.identity] != nil }
    }

    public var isUpdatesFilterAvailable: Bool { tab == .all && activeCollection == nil && filter == .all }

    public func setShowUpdatesOnly(_ value: Bool) {
        showUpdatesOnly = value
        preferences.setShowUpdatesOnly(value)
    }

    /// Selecting a tab restores that tab's own layout and sort. There is no pager: a tab is chosen.
    public func selectTab(_ selected: LibraryTab) async {
        tab = selected
        filter = selected.filter
        endSelection()
        restorePresentation(for: selected)
        if activeCollection != nil { await open(collection: nil) }
    }

    private func restorePresentation(for selected: LibraryTab) {
        let stored = preferences.library.tabPresentations[selected.rawValue] ?? selected.defaultPresentation
        restoringPresentation = true
        layout = LibraryLayout(rawValue: stored.layout) ?? .grid
        sort = LibrarySortMode(rawValue: stored.sortMode) ?? .smart
        sortDescending = stored.sortDescending
        restoringPresentation = false
    }

    private func persistPresentation() {
        guard !restoringPresentation else { return }
        preferences.setTabPresentation(
            tab.rawValue,
            LibraryTabPresentation(layout: layout.rawValue, sortMode: sort.rawValue, sortDescending: sortDescending)
        )
    }

    public func update(for identity: BookIdentity) -> UnresolvedUpdate? {
        unresolvedUpdates[identity]
    }

    public var updateStore: UpdateStore? { updates }

    /// A terminal session's strip stays until dismissed, except a clean completion, which says so
    /// for two seconds from its durable finish time and then leaves on its own.
    public var isReportStripVisible: Bool {
        guard let session = updateSession, session.state.isTerminal, session.sessionId != dismissedSessionId else {
            return false
        }
        if session.state == .completed, let finished = session.finishedAt {
            return clock().timeIntervalSince(finished) < 2
        }
        return true
    }

    public func dismissReportStrip() {
        dismissedSessionId = updateSession?.sessionId
    }

    // MARK: Updates

    /// `立即检查` runs a manual session and keeps the status strip current while it does.
    public func checkUpdatesNow() async {
        guard let checker, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let run = Task { await checker.run(trigger: .manual) }
        while !run.isCancelled {
            await loadUpdateState()
            if let session = updateSession, session.state == .running || session.state == .queued {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            if await checker.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            break
        }
        _ = await run.value
        await load()
    }

    public func cancelUpdateCheck() async {
        guard let checker else { return }
        _ = await checker.cancel()
        await loadUpdateState()
    }

    /// Ignoring names the exact detection the reader saw; it never touches reading progress.
    public func ignoreUpdate(_ identity: BookIdentity) async {
        guard let updates, let current = unresolvedUpdates[identity] else { return }
        undoIgnoreToken = try? await updates.ignore(identity, anchor: current.anchor, now: clock())
        await loadUpdateState()
    }

    public func undoIgnore() async {
        guard let updates, let token = undoIgnoreToken else { return }
        undoIgnoreToken = nil
        _ = try? await updates.undo(token: token, now: clock())
        await loadUpdateState()
    }

    public func dismissUndo() {
        undoIgnoreToken = nil
    }

    /// A book that lives only in a website mirror still has updates worth showing. It appears as an
    /// entry without local membership, so opening it creates no pin.
    private func mirrorOnlyEntriesWithUpdates(excluding known: Set<BookIdentity>) async throws -> [LibraryEntry] {
        var result: [LibraryEntry] = []
        for identity in unresolvedUpdates.keys.sorted() where !known.contains(identity) {
            guard let book = try await library.book(identity) else { continue }
            if let entry = try await library.libraryEntry(identity) {
                result.append(entry)
                continue
            }
            result.append(
                try LibraryEntry(
                    book: book, libraryAddedAt: book.addedAt, rating: nil, localTags: [],
                    readLater: false, localMembership: false, sourceAvailable: true, reconciliation: nil
                )
            )
        }
        return result
    }

    private func loadUpdateState() async {
        guard let updates else { return }
        let detected = (try? await updates.unresolvedUpdates()) ?? []
        unresolvedUpdates = Dictionary(detected.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        updateSession = try? await updates.latestSession()
    }

    /// The tabs already stand for 全部/继续阅读/稍后再读, so the shortcut bar carries only the nodes
    /// the tabs do not: today that is 来源休眠, beside collections and website mirrors — and only
    /// while some book's source actually is dormant, since an empty view is not an entry point.
    public var visibleSystemNodes: [SystemLibraryFilter] {
        let tabbed = Set(LibraryTab.allCases.map(\.filter))
        let hasDormant = entries.contains { !$0.sourceAvailable }
        return SystemLibraryFilter.allCases.filter {
            !hiddenSystemNodes.contains($0) && !tabbed.contains($0) && ($0 != .dormant || hasDormant)
        }
    }

    public var manualCollections: [LibraryCollection] {
        allCollections.filter { $0.kind == .manual }
    }

    /// Local removal of one book, from its own menu. The book stays on the site; nothing is sent.
    public func removeBook(_ identity: BookIdentity) async {
        _ = try? await library.removeFromLibrary(identity)
        await load()
    }

    public func setReadLater(_ identity: BookIdentity, _ readLater: Bool) async {
        try? await library.setReadLater(identity, readLater: readLater)
        await load()
    }

    public var isSelecting: Bool { selectionKind != nil }

    public var isShortcutBarLocked: Bool { preferences.library.shortcutLocked }

    public var shortcuts: [LibraryShortcut] {
        LibraryShortcutOrder.resolve(
            storedOrder: preferences.library.shortcutOrder,
            systemNodes: visibleSystemNodes,
            collections: allCollections,
            mirrors: mirrors
        )
    }

    public func title(of shortcut: LibraryShortcut) -> String {
        switch shortcut {
        case .system(let filter): return filter.title
        case .collection(let id):
            return allCollections.first { $0.collectionId == id }?.title ?? id
        case .mirror(let sourceId):
            return mirrors.first { $0.sourceId == sourceId }?.displayName ?? sourceId
        }
    }

    public func setShortcutBarLocked(_ locked: Bool) {
        preferences.setShortcutLocked(locked)
        objectWillChange.send()
    }

    /// Reordering writes the whole resolved order, so a later collection rename or a hidden system
    /// node cannot leave a gap the stored list still claims.
    public func moveShortcut(from source: IndexSet, to destination: Int) {
        var current = shortcuts
        current.move(fromOffsets: source, toOffset: destination)
        preferences.setShortcutOrder(current.map { $0.id })
        objectWillChange.send()
    }

    public func activate(_ shortcut: LibraryShortcut) async {
        switch shortcut {
        case .system(let node):
            await open(collection: nil)
            filter = node
        case .collection(let id):
            guard let collection = allCollections.first(where: { $0.collectionId == id }) else { return }
            await open(collection: collection)
        case .mirror:
            break
        }
    }

    public func load() async {
        await loadUpdateState()
        do {
            if let collection = activeCollection {
                entries = try await collections.collectionEntries(collection.collectionId)
            } else if tab == .readLater {
                entries = try await library.readLaterEntries()
            } else {
                entries = try await library.libraryEntries()
            }
            if activeCollection == nil, tab == .all {
                entries += try await mirrorOnlyEntriesWithUpdates(excluding: Set(entries.map(\.book.identity)))
            }
            allCollections = try await collections.collections()
            mirrors = ((try? await mirrorStore?.bindings()) ?? []).filter { !$0.frozen }
            guard !entries.isEmpty || !allCollections.isEmpty else {
                state = .empty(title: "书架还是空的", detail: "在来源里找到一本书，然后加入书架。")
                return
            }
            state = .content(LibraryContent(entries: entries))
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取本地书架。")
        }
    }

    public func cycleLayout() {
        layout = layout.next
    }

    /// Arranging is only meaningful over the whole shelf in its own order, so entering it puts the
    /// shelf back into that state rather than persisting an order the reader cannot see.
    public func setArranging(_ arranging: Bool) async {
        isArranging = arranging
        guard arranging else { return }
        endSelection()
        sort = .custom
        sortDescending = false
        filter = .all
        if activeCollection != nil { await open(collection: nil) }
    }

    /// Persists the shelf's own order. Only reachable while arranging, so a drag can never contradict
    /// a computed order.
    public func move(_ identity: BookIdentity, to index: Int) async {
        guard isArranging else { return }
        var order = project(entries).map { $0.book.identity }
        guard let from = order.firstIndex(of: identity) else { return }
        order.remove(at: from)
        order.insert(identity, at: min(max(index, 0), order.count))
        try? await library.reorderLibrary(order)
        await load()
    }

    /// A collection is a view over the same shelf, not a second shelf: it reuses the same entry list,
    /// filters and selection.
    public func open(collection: LibraryCollection?) async {
        activeCollection = collection
        filter = .all
        endSelection()
        await load()
    }

    public func setSystemNode(_ node: SystemLibraryFilter, hidden: Bool) {
        guard node != .all else { return }
        if hidden {
            hiddenSystemNodes.insert(node)
            if filter == node { filter = .all }
        } else {
            hiddenSystemNodes.remove(node)
        }
        preferences.setHiddenSystemNodes(hiddenSystemNodes.map { $0.rawValue }.sorted())
    }

    public func beginSelection(book: BookIdentity) {
        selectionKind = .books
        selectedBooks = [book]
        selectedCollections = []
    }

    public func beginSelection(collection: String) {
        selectionKind = .collections
        selectedCollections = [collection]
        selectedBooks = []
    }

    public func toggle(book: BookIdentity) {
        guard selectionKind == .books else { return }
        if selectedBooks.contains(book) {
            selectedBooks.remove(book)
        } else {
            selectedBooks.insert(book)
        }
        if selectedBooks.isEmpty { endSelection() }
    }

    public func toggle(collection: String) {
        guard selectionKind == .collections else { return }
        if selectedCollections.contains(collection) {
            selectedCollections.remove(collection)
        } else {
            selectedCollections.insert(collection)
        }
        if selectedCollections.isEmpty { endSelection() }
    }

    public func selectAll() {
        switch selectionKind {
        case .books: selectedBooks = Set(project(entries).map { $0.book.identity })
        case .collections: selectedCollections = Set(allCollections.map(\.collectionId))
        case nil: break
        }
    }

    public func endSelection() {
        selectionKind = nil
        selectedBooks = []
        selectedCollections = []
    }

    /// Local removal only. The book stays on the site; nothing is sent anywhere.
    public func removeSelectedBooks() async {
        guard !selectedBooks.isEmpty else { return }
        _ = try? await library.removeFromLibrary(selectedBooks)
        endSelection()
        await load()
    }

    public func addBooks(_ identities: [BookIdentity], to collectionId: String) async {
        guard !identities.isEmpty else { return }
        _ = try? await collections.addManualMemberships(collectionId, identities)
        endSelection()
        await load()
    }

    /// Deleting a collection removes the grouping only; every book in it stays on the shelf.
    public func deleteCollection(_ collectionId: String) async {
        _ = try? await collections.deleteCollection(collectionId)
        if activeCollection?.collectionId == collectionId { activeCollection = nil }
        endSelection()
        await load()
    }

    public func deleteSelectedCollections() async {
        for collectionId in selectedCollections {
            _ = try? await collections.deleteCollection(collectionId)
        }
        endSelection()
        await load()
    }

    /// Dropping one book on another makes a collection holding both, which is the only way to create
    /// one without leaving the shelf.
    public func createCollection(named title: String, from books: [BookIdentity]) async {
        guard !books.isEmpty, let collection = record(title, kind: .manual) else { return }
        try? await collections.createManualCollectionWithMemberships(collection, identities: books)
        endSelection()
        await load()
    }

    public func createManualCollection(named title: String) async {
        guard let collection = record(title, kind: .manual) else { return }
        try? await collections.createCollection(collection)
        await load()
    }

    public func createSmartCollection(named title: String, rule: SmartRule) async {
        guard let collection = record(title, kind: .smart) else { return }
        try? await collections.createSmartCollection(collection, rule: rule)
        await load()
    }

    private func record(_ title: String, kind: CollectionKind) -> LibraryCollection? {
        try? LibraryCollection(
            collectionId: UUID().uuidString,
            kind: kind,
            title: title,
            parentCollectionId: nil,
            displayOrder: Int64(allCollections.count)
        )
    }
}
