// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import BrowseFeature
import ExtensionsFeature
import Foundation
import os
import TsuyomiApp
import TsuyomiCore
import TsuyomiProtocol
import LibraryFeature
import TsuyomiRemoteLibrary
import TsuyomiSource
import TsuyomiUpdates
import XCTest

/// A source installed through the real lifecycle, signed in, and answered by a transport that
/// routes on the request rather than on a forced page: the shelf, its folders, and each of the
/// three website writes have their own answers, and every write is counted.
@MainActor
struct MirrorWorld {
    let sourceId: SourceId
    let registry: SourceRegistry
    let library: LibraryRepository
    let remoteLibrary: RemoteLibraryStore
    let mirror: RemoteMirrorStore
    let updates: UpdateStore
    let progress: ReadingProgressStore
    let coordinator: RemoteLibraryCoordinator
    let updateCoordinator: UpdateCoordinator
    let lifecycle: ExtensionLifecycle
    let preferences: AppPreferences
    let transport: MirrorTransport
    let installedSourceId: SourceId
    private let databaseHandle: TsuyomiDatabase

    init(directory: URL, signedIn: Bool = true) async throws {
        sourceId = try SourceId("org.tsuyomi.wenku8")
        installedSourceId = sourceId
        transport = MirrorTransport()
        let roots = try StorageRoots(base: directory)
        let database = try TsuyomiDatabase(path: directory.appendingPathComponent("t.sqlite").path)
        databaseHandle = database
        library = LibraryRepository(database: database)
        remoteLibrary = RemoteLibraryStore(database: database)
        mirror = RemoteMirrorStore(database: database)
        updates = UpdateStore(database: database)
        progress = ReadingProgressStore(database: database)
        preferences = AppPreferences(defaults: UserDefaults(suiteName: "mirror-\(UUID().uuidString)") ?? .standard)
        let files = try QuotaFileStore(
            roots: roots,
            root: .extensions,
            namespace: "installed-extensions",
            quota: StorageQuota(maximumBytes: 64 * 1024 * 1024, maximumEntries: 64)
        )
        let installed = InstalledExtensionStore(files: files)
        let trust = PublisherTrustStore(files: files)
        let grants = PackageGrantStore(files: files)
        #if DEBUG
        let key = try Phase2TestPublisher.key()
        #else
        throw XCTSkip("The fixture publisher is only compiled into DEBUG builds")
        #endif
        try await trust.approve(
            TrustedPublisher(
                keyId: key.keyId, publicKey: key.publicKey, trust: .builtInTest, repositoryId: nil, approvedAt: Date()
            )
        )
        let hostApi = try SemanticVersion(AppContainer.hostApiVersion)
        let installer = ExtensionInstaller(
            verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApi),
            store: installed,
            grants: grants
        )
        let credentials = try SourceCredentialStore(roots: roots, aead: TestPassthroughAead())
        let sessions = VerifiedBrowserSessionStore(credentials: credentials)
        if signedIn {
            try await sessions.put(
                try SourceCredentialPartition(sourceId: sourceId.value, origin: try HttpsOrigin("https://www.wenku8.net")),
                session: try VerifiedBrowserSession(requestCookies: "session=verified", userAgent: AppContainer.userAgent)
            )
        }
        let tokens = DirectActionTokenRegistry()
        registry = SourceRegistry(
            installer: installer,
            store: installed,
            gateway: HostNetworkGateway(transport: transport, directActionTokens: tokens),
            sessions: sessions
        )
        lifecycle = ExtensionLifecycle(
            installed: installed,
            registry: registry,
            remoteLibrary: remoteLibrary,
            trust: trust,
            grants: grants,
            gate: ExtensionMutationGate(),
            hostApiVersion: hostApi
        )
        let prepared = try await installer.prepare(archiveBytes: try JourneyFixtures.data("wenku8-fixture.hxp"))
        try await lifecycle.activate(prepared)
        coordinator = RemoteLibraryCoordinator(
            registry: registry,
            remoteLibrary: remoteLibrary,
            mirror: mirror,
            library: library,
            sessions: sessions,
            tokens: tokens
        )
        updateCoordinator = UpdateCoordinator(
            registry: registry,
            updates: updates,
            library: library,
            mirror: mirror,
            remoteLibrary: remoteLibrary,
            progress: progress
        )
    }

    func libraryModel() -> LibraryModel {
        LibraryModel(
            library: library,
            collections: CollectionStore(database: databaseHandle),
            preferences: preferences,
            mirrors: mirror,
            updates: updates,
            checker: updateCoordinator
        )
    }

    func mirrorModel(targetId: String? = nil) -> RemoteLibraryModel {
        RemoteLibraryModel(
            sourceId: sourceId,
            targetId: targetId,
            coordinator: coordinator,
            mirror: mirror,
            library: library,
            preferences: preferences
        )
    }

    func shelfModel(_ identity: BookIdentity) -> BookRemoteShelfModel {
        BookRemoteShelfModel(
            identity: identity,
            coordinator: coordinator,
            mirror: mirror,
            remoteLibrary: remoteLibrary,
            preferences: preferences
        )
    }

    func identity(_ remoteBookId: String) throws -> BookIdentity {
        try BookIdentity(sourceId: sourceId.value, remoteBookId: remoteBookId)
    }
}

/// Round-trips plaintext so a credential store can be exercised without a Keychain-backed key,
/// which unit tests have no entitlement for. It authenticates nothing on purpose.
struct TestPassthroughAead: AeadPort {
    func encrypt(plaintext: Data, additionalAuthenticatedData: Data) throws -> AeadCiphertext {
        AeadCiphertext(iv: Data(count: 12), ciphertext: plaintext)
    }

    func decrypt(_ value: AeadCiphertext, additionalAuthenticatedData: Data) throws -> Data {
        value.ciphertext
    }
}

/// Routes on path, query and form body. Writes answer with the typed outcome the extension's own
/// tests use; each can be made to fail on demand, before or after the request would have landed.
final class MirrorTransport: HostHttpTransport {
    enum Failure { case transport, sessionExpired }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var requests: [HostHttpRequest] = []
        var failNext: Failure?
        var removeOutcome = "applied"
        var moveOutcome = "applied"
        var directoryPage = "directory"
    }

    var requests: [HostHttpRequest] { state.withLock { $0.requests } }

    var writes: [HostHttpRequest] {
        requests.filter { $0.method != .get || $0.url.path.contains("addbookcase") }
    }

    func failNext(_ failure: Failure) {
        state.withLock { $0.failNext = failure }
    }

    func setRemoveOutcome(_ outcome: String) {
        state.withLock { $0.removeOutcome = outcome }
    }

    /// The page the source's directory and update-check requests read.
    func setDirectoryPage(_ name: String) {
        state.withLock { $0.directoryPage = name }
    }

    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        let (failure, remove, move, directory) = state.withLock { current -> (Failure?, String, String, String) in
            current.requests.append(request)
            let failure = current.failNext
            current.failNext = nil
            return (failure, current.removeOutcome, current.moveOutcome, current.directoryPage)
        }
        if failure == .transport { throw HostNetworkException(.transport) }
        let url = request.url.absoluteString
        let form = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let html: String
        if failure == .sessionExpired {
            html = try MirrorTransport.utf8("login")
        } else if url.contains("action=targets") {
            html = try MirrorTransport.utf8("remote-library-page-1")
        } else if url.contains("action=list") {
            html = try MirrorTransport.utf8(url.contains("cursor=page-2") ? "remote-library-page-2" : "remote-library-page-1")
        } else if url.contains("addbookcase.php") {
            html = try MirrorTransport.utf8("remote-add-applied")
        } else if form.contains("action=remove") {
            let book = MirrorTransport.formValue(form, "aid")
            html = "<div data-outcome=\"\(remove)\" data-book-id=\"\(book)\"></div>"
        } else if form.contains("action=move") {
            let book = MirrorTransport.formValue(form, "aid")
            let target = MirrorTransport.formValue(form, "target")
            html = "<div data-outcome=\"\(move)\" data-book-id=\"\(book)\" data-target-id=\"\(target)\"></div>"
        } else if url.contains("search.php") {
            html = try MirrorTransport.utf8("search")
        } else if url.contains("cid=") {
            html = try MirrorTransport.utf8("chapter")
        } else if url.contains("reader.php") {
            html = try MirrorTransport.utf8(directory)
        } else {
            html = try MirrorTransport.utf8("detail")
        }
        return HostHttpResponse(
            status: 200,
            finalUrl: request.url,
            headers: ["content-type": "text/html; charset=gb18030"],
            bytes: try MirrorTransport.gb18030(html)
        )
    }

    private static func formValue(_ form: String, _ name: String) -> String {
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == Substring(name) { return String(parts[1]) }
        }
        return ""
    }

    private static func utf8(_ name: String) throws -> String {
        guard let text = String(data: try JourneyFixtures.data("\(name).html"), encoding: .utf8) else {
            throw XCTSkip("Cannot read fixture \(name)")
        }
        return text
    }

    private static func gb18030(_ text: String) throws -> Data {
        guard let encoded = text.data(
            using: String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        ) else { throw XCTSkip("Cannot re-encode fixture") }
        return encoded
    }
}
