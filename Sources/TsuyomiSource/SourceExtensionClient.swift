// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// Host-owned orchestration for one verified extension version. JavaScript builds requests and parses
/// bounded text; the host validates transport and converts JSON into strict protocol values. The
/// extension never receives a Foundation object, a cookie, or a response header.
public final class SourceExtensionClient: Sendable {
    public let packageInfo: VerifiedHxpPackage
    private let gateway: HostNetworkGateway
    private let runtime: QuickJsRuntimeLane
    private let grant: SourceNetworkGrant

    private init(
        packageInfo: VerifiedHxpPackage,
        gateway: HostNetworkGateway,
        runtime: QuickJsRuntimeLane
    ) throws {
        let manifest = packageInfo.manifest
        self.packageInfo = packageInfo
        self.gateway = gateway
        self.runtime = runtime
        self.grant = try SourceNetworkGrant(
            sourceId: manifest.sourceId.value,
            extensionVersion: manifest.version.original,
            origins: manifest.capabilities.network.origins,
            cookieMode: manifest.capabilities.cookies.sourceScoped ? .sourceScoped : .none,
            cookieOrigins: manifest.capabilities.cookies.origins,
            maximumConcurrentRequests: manifest.capabilities.network.maximumConcurrentRequests,
            requestTimeoutMs: manifest.capabilities.network.requestTimeoutMs,
            maximumResponseBytes: manifest.capabilities.network.maximumResponseBytes,
            remoteAddPolicy: try manifest.capabilities.remoteLibrary.policies[.add]?.networkPolicy()
        )
    }

    public static func open(
        packageInfo: VerifiedHxpPackage,
        gateway: HostNetworkGateway
    ) async throws -> SourceExtensionClient {
        let manifest = packageInfo.manifest
        let runtime = try QuickJsRuntimeLane(
            limits: try QuickJsRuntimeLimits(
                maximumMemoryBytes: Int64(manifest.resourceLimits.maximumMemoryBytes),
                maximumExecutionWallTimeMs: manifest.resourceLimits.maximumExecutionWallTimeMs
            )
        )
        do {
            try await runtime.evaluateModule(source: packageInfo.entryModuleBytes, filename: manifest.entry)
            return try SourceExtensionClient(packageInfo: packageInfo, gateway: gateway, runtime: runtime)
        } catch {
            await runtime.close()
            throw error
        }
    }

    public func close() async {
        await runtime.close()
    }

    public var manifest: HxpManifest { packageInfo.manifest }

    public func searchRequestUrl(query: String, page: Int = 1) async throws -> String {
        try await requestUrl("buildSearchRequest", [.string(query), .int(page)], stage: "search-network")
    }

    public func detailRequestUrl(remoteBookId: String) async throws -> String {
        try await requestUrl("buildDetailRequest", [.string(remoteBookId)], stage: "detail-network")
    }

    public func directoryRequestUrl(remoteBookId: String) async throws -> String {
        try await requestUrl("buildDirectoryRequest", [.string(remoteBookId)], stage: "directory-network")
    }

    public func chapterRequestUrl(_ chapter: SourceChapter, remoteBookId: String) async throws -> String {
        try await requestUrl(
            "buildChapterRequest",
            [.string(chapter.url), .string(remoteBookId), .string(chapter.chapterId)],
            stage: "chapter-network"
        )
    }

    public func search(
        query: String,
        page: Int = 1,
        offlineOnly: Bool = false
    ) async throws -> [SourceBookSummary] {
        let response = try await invokeNetwork(
            "buildSearchRequest",
            [.string(query), .int(page)],
            stage: "search-network",
            offlineOnly: offlineOnly
        )
        try await classify(response, stage: "search-classify", operation: "search")
        let root = try await callObject(
            "parseSearch",
            [.string(response.text ?? ""), .string(response.finalUrl)],
            stage: "search-parse"
        )
        return try SourceExtensionMarshalling.summaries(root, stage: "search-parse")
    }

    public func home(
        selectedFilters: [String: String] = [:],
        cursor: String? = nil
    ) async throws -> SourceHomePage {
        guard manifest.capabilities.home.enabled else {
            throw SourceExtensionMarshalling.failure(.malformedSourceResponse, "home", "home-not-granted")
        }
        guard selectedFilters.count <= 16,
              selectedFilters.allSatisfy({ Grammar.isToken($0.key, limit: 64) && Grammar.isToken($0.value, limit: 64) })
        else {
            throw SourceExtensionMarshalling.failure(.malformedSourceResponse, "home", "invalid-home-filters")
        }
        let arguments: [JSONValue] = [
            cursor.map { JSONValue.string($0) } ?? .null,
            .object(selectedFilters.mapValues { .string($0) })
        ]
        let response = try await invokeNetwork(
            "buildHomeRequest",
            arguments,
            stage: "home-network",
            offlineOnly: false
        )
        try await classify(response, stage: "home-classify", operation: "home")
        let root = try await callObject(
            "parseHome",
            [.string(response.text ?? ""), arguments[0], arguments[1]],
            stage: "home-parse"
        )
        return try SourceExtensionMarshalling.homePage(root)
    }

    public func detail(remoteBookId: String, offlineOnly: Bool = false) async throws -> SourceBookDetail {
        let response = try await invokeNetwork(
            "buildDetailRequest",
            [.string(remoteBookId)],
            stage: "detail-network",
            offlineOnly: offlineOnly
        )
        try await classify(
            response,
            stage: "detail-classify",
            operation: "detail",
            remoteBookId: remoteBookId
        )
        let root = try await callObject(
            "parseDetail",
            [.string(response.text ?? ""), .string(remoteBookId)],
            stage: "detail-parse"
        )
        return try SourceExtensionMarshalling.detail(root)
    }

    public func directory(remoteBookId: String, offlineOnly: Bool = false) async throws -> SourceDirectory {
        let response = try await invokeNetwork(
            "buildDirectoryRequest",
            [.string(remoteBookId)],
            stage: "directory-network",
            offlineOnly: offlineOnly
        )
        try await classify(
            response,
            stage: "directory-classify",
            operation: "directory",
            remoteBookId: remoteBookId
        )
        let root = try await callObject(
            "parseDirectory",
            [.string(response.text ?? ""), .string(remoteBookId)],
            stage: "directory-parse"
        )
        return try SourceExtensionMarshalling.directory(root)
    }

    public func chapter(
        _ chapter: SourceChapter,
        remoteBookId: String,
        offlineOnly: Bool = false
    ) async throws -> ReaderDocument {
        let response = try await invokeNetwork(
            "buildChapterRequest",
            [.string(chapter.url), .string(remoteBookId), .string(chapter.chapterId)],
            stage: "chapter-network",
            offlineOnly: offlineOnly
        )
        try await classify(
            response,
            stage: "chapter-classify",
            operation: "chapter",
            remoteBookId: remoteBookId,
            chapterId: chapter.chapterId
        )
        let root = try await callObject(
            "parseChapter",
            [
                .string(response.text ?? ""), .string(remoteBookId),
                .string(chapter.chapterId), .string(chapter.title)
            ],
            stage: "chapter-parse"
        )
        return try SourceExtensionMarshalling.document(root)
    }

    public func listRemoteLibrary(cursor: String?) async throws -> RemoteLibraryPage {
        guard let policy = manifest.capabilities.remoteLibrary.policies[.read] else {
            throw SourceExtensionMarshalling.failure(
                .malformedSourceResponse, "remote-library-read", "remote-read-not-granted"
            )
        }
        let response = try await invokeNetwork(
            "buildRemoteLibraryRequest",
            [cursor.map { JSONValue.string($0) } ?? .null],
            stage: "remote-library-read-network",
            offlineOnly: false,
            operationContext: try remoteLibraryReadContext(policy: try policy.networkPolicy(), cursor: cursor)
        )
        try await classify(response, stage: "remote-library-read-classify", operation: "remote-library")
        let root = try await callObject(
            "parseRemoteLibrary",
            [.string(response.text ?? "")],
            stage: "remote-library-read-parse"
        )
        return try SourceExtensionMarshalling.remoteLibraryPage(root)
    }

    public func addRemoteLibrary(
        remoteBookId: String,
        directActionToken: String
    ) async throws -> RemoteLibraryAddResult {
        guard let policy = manifest.capabilities.remoteLibrary.policies[.add] else {
            throw SourceExtensionMarshalling.failure(
                .malformedSourceResponse, "remote-library-add", "remote-add-not-granted"
            )
        }
        let response = try await invokeNetwork(
            "buildRemoteLibraryAddRequest",
            [.string(remoteBookId)],
            stage: "remote-library-add-network",
            offlineOnly: false,
            operationContext: try remoteLibraryAddContext(
                policy: try policy.networkPolicy(),
                remoteBookId: remoteBookId,
                addToken: directActionToken
            )
        )
        try await classify(response, stage: "remote-library-add-classify")
        let root = try await callObject(
            "parseRemoteLibraryAdd",
            [.string(response.text ?? ""), .string(remoteBookId)],
            stage: "remote-library-add-parse"
        )
        return try SourceExtensionMarshalling.remoteAddResult(
            root,
            expectedSourceId: manifest.sourceId.value,
            expectedRemoteBookId: remoteBookId
        )
    }

    private func invokeNetwork(
        _ function: String,
        _ arguments: [JSONValue],
        stage: String,
        offlineOnly: Bool,
        operationContext: SourceOperationContext? = nil
    ) async throws -> SourceNetworkResponse {
        let request = try await buildNetworkRequest(function, arguments, stage: stage, offlineOnly: offlineOnly)
        do {
            return try await gateway.request(grant: grant, request: request, operationContext: operationContext)
        } catch let failure as HostNetworkException {
            throw SourceExtensionMarshalling.failure(
                SourceExtensionMarshalling.mapNetworkError(failure.error),
                stage,
                failure.error.rawValue.lowercased(),
                correlationId: failure.diagnosticId
            )
        }
    }

    private func requestUrl(
        _ function: String,
        _ arguments: [JSONValue],
        stage: String
    ) async throws -> String {
        let request = try await buildNetworkRequest(function, arguments, stage: stage, offlineOnly: false)
        guard request.method == .get, request.form == nil, request.utf8Body == nil else {
            throw SourceExtensionMarshalling.failure(
                .malformedSourceResponse, "\(stage)-request", "verified-page-request-not-get"
            )
        }
        return request.url
    }

    private func buildNetworkRequest(
        _ function: String,
        _ arguments: [JSONValue],
        stage: String,
        offlineOnly: Bool
    ) async throws -> SourceNetworkRequest {
        let root = try await callObject(function, arguments, stage: "\(stage)-request")
        do {
            return try SourceExtensionMarshalling.request(root, offlineOnly: offlineOnly)
        } catch let failure as SourceException {
            throw failure
        } catch {
            throw SourceExtensionMarshalling.failure(
                .extensionRuntimeFailure, "\(stage)-request", "invalid-request-dto"
            )
        }
    }

    private func classify(
        _ response: SourceNetworkResponse,
        stage: String,
        operation: String = "generic",
        remoteBookId: String? = nil,
        chapterId: String? = nil
    ) async throws {
        let arguments: [JSONValue] = [
            .string(response.text ?? ""), .string(response.finalUrl), .string(operation),
            remoteBookId.map { JSONValue.string($0) } ?? .null,
            chapterId.map { JSONValue.string($0) } ?? .null
        ]
        let result = try await call("classifyPage", arguments, stage: stage)
        switch result.stringValue {
        case "ok":
            return
        case "session-required":
            throw SourceExtensionMarshalling.failure(.sessionRequired, stage, "session-required")
        case "verification-required":
            throw SourceExtensionMarshalling.failure(.verificationRequired, stage, "verification-required")
        case "malformed":
            throw SourceExtensionMarshalling.failure(.malformedSourceResponse, stage, "wrong-page")
        default:
            throw SourceExtensionMarshalling.failure(
                .malformedSourceResponse, stage, "invalid-page-classification"
            )
        }
    }

    private func callObject(
        _ function: String,
        _ arguments: [JSONValue],
        stage: String
    ) async throws -> [String: JSONValue] {
        guard let object = try await call(function, arguments, stage: stage).objectValue else {
            throw SourceExtensionMarshalling.failure(.malformedSourceResponse, stage, "invalid-json-result")
        }
        return object
    }

    private func call(
        _ function: String,
        _ arguments: [JSONValue],
        stage: String
    ) async throws -> JSONValue {
        guard let encoded = try? JSONValue.array(arguments).encoded(),
              let argumentsJson = String(data: encoded, encoding: .utf8) else {
            throw SourceExtensionMarshalling.failure(.extensionRuntimeFailure, stage, "invalid-arguments")
        }
        let result: String
        do {
            result = try await runtime.callJson(functionName: function, argumentsJson: argumentsJson)
        } catch let failure as QuickJsRuntimeError {
            let code: SourceErrorCode
            switch failure {
            case .executionLimit: code = .extensionTimeout
            case .cancelled: code = .extensionCancelled
            default: code = .extensionRuntimeFailure
            }
            throw SourceExtensionMarshalling.failure(code, stage, failure.rawValue.lowercased())
        }
        guard let parsed = try? JSONValue.decode(Data(result.utf8)) else {
            throw SourceExtensionMarshalling.failure(.malformedSourceResponse, stage, "invalid-json-result")
        }
        return parsed
    }
}

/// Covers travel the same granted origins, cookie scope and response caps as documents. The grant
/// stays private to the client, so no display path can widen it.
extension SourceExtensionClient: CoverMediaFetcher {
    public func fetch(url: String, referrerUrl: String?) async throws -> CoverMediaPayload {
        let response = try await gateway.fetchMedia(grant: grant, url: url, referrerUrl: referrerUrl)
        return CoverMediaPayload(bytes: response.bytes, contentType: response.contentType)
    }
}
