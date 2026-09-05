// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

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
    @Published public var layout: LibraryLayout = .grid
    @Published public var sort: LibrarySortMode = .custom
    @Published public var sortDescending = false
    @Published public private(set) var selectionKind: LibrarySelectionKind?
    @Published public private(set) var selectedBooks: Set<BookIdentity> = []
    @Published public private(set) var selectedCollections: Set<String> = []
    @Published public private(set) var hiddenSystemNodes: Set<SystemLibraryFilter> = []
    @Published public private(set) var activeCollection: LibraryCollection?
    @Published public var isShortcutBarCollapsed = false
    @Published public private(set) var isArranging = false

    private let library: LibraryRepository
    private let collections: CollectionStore
    private let preferences: AppPreferences
    private var entries: [LibraryEntry] = []
    private var allCollections: [LibraryCollection] = []

    public init(library: LibraryRepository, collections: CollectionStore, preferences: AppPreferences) {
        self.library = library
        self.collections = collections
        self.preferences = preferences
        hiddenSystemNodes = Set(
            preferences.library.hiddenSystemNodes.compactMap(SystemLibraryFilter.init(rawValue:))
        )
    }

    public func project(_ values: [LibraryEntry]) -> [LibraryEntry] {
        LibraryProjection.apply(values, filter: filter, sort: sort, descending: sortDescending)
    }

    public var visibleSystemNodes: [SystemLibraryFilter] {
        SystemLibraryFilter.allCases.filter { !hiddenSystemNodes.contains($0) }
    }

    public var isSelecting: Bool { selectionKind != nil }

    public var isShortcutBarLocked: Bool { preferences.library.shortcutLocked }

    public var shortcuts: [LibraryShortcut] {
        LibraryShortcutOrder.resolve(
            storedOrder: preferences.library.shortcutOrder,
            systemNodes: visibleSystemNodes,
            collections: allCollections
        )
    }

    public func title(of shortcut: LibraryShortcut) -> String {
        switch shortcut {
        case .system(let filter): return filter.title
        case .collection(let id):
            return allCollections.first { $0.collectionId == id }?.title ?? id
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
        }
    }

    public func load() async {
        do {
            if let collection = activeCollection {
                entries = try await collections.collectionEntries(collection.collectionId)
            } else {
                entries = try await library.libraryEntries()
            }
            allCollections = try await collections.collections()
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
        guard !books.isEmpty else { return }
        let collection = try? LibraryCollection(
            collectionId: UUID().uuidString,
            kind: .manual,
            title: title,
            parentCollectionId: nil,
            displayOrder: Int64(allCollections.count)
        )
        guard let collection else { return }
        try? await collections.createManualCollectionWithMemberships(collection, identities: books)
        endSelection()
        await load()
    }
}
