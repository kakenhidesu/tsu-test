// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiApp
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import UIKit
import XCTest

/// A cover that failed once is not failed for the rest of the run: the lane was closing, the network
/// was away, the site was challenging. Coming back to the screen asks again, exactly once more.
final class CoverRetryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cover-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testAFailedCoverIsAskedForAgainWhenTheScreenComesBack() async throws {
        let world = try await FixtureWorld(directory: directory)
        let sources = try await world.registry.installedSources()
        let source = try XCTUnwrap(sources.first { $0.sourceId == world.sourceId })
        let fetcher = FlakyCoverFetcher(image: Self.jpeg())
        let provider = try SourceCoverProvider(
            source: source,
            credentialRevision: "anonymous",
            roots: try StorageRoots(base: directory),
            fetcher: fetcher
        )
        let identity = try BookIdentity(sourceId: world.sourceId.value, remoteBookId: "1234")
        func ask() -> CoverUiState {
            provider.state(
                identity: identity,
                title: "雾港纪事",
                coverUrl: "https://img.wenku8.com/image/12/1234/1234s.jpg",
                referrerUrl: "https://www.wenku8.net/book/1234.htm",
                width: CoverPixels.width,
                height: CoverPixels.height
            )
        }

        _ = ask()
        let failed = await settles { if case .failed = ask() { return true } else { return false } }
        XCTAssertTrue(failed, "the first attempt fails and says so")
        _ = ask()
        let callsWhileFailed = await fetcher.calls
        XCTAssertEqual(callsWhileFailed, 1, "a failed cover is not fetched again on every draw")

        provider.retryFailed()
        _ = ask()
        let ready = await settles { if case .ready = ask() { return true } else { return false } }
        XCTAssertTrue(ready, "coming back to the screen asks again, and this time the cover arrives")
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 2)

        provider.retryFailed()
        _ = ask()
        let callsAfterSuccess = await fetcher.calls
        XCTAssertEqual(callsAfterSuccess, 2, "a cover that arrived is not asked for again")
    }

    @MainActor
    private func settles(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @MainActor
    private static func jpeg() -> Data {
        let size = CGSize(width: 8, height: 12)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Fails the first request and serves the image from then on.
private actor FlakyCoverFetcher: CoverMediaFetcher {
    private(set) var calls = 0
    private let image: Data

    init(image: Data) {
        self.image = image
    }

    func fetch(url: String, referrerUrl: String?) async throws -> CoverMediaPayload {
        calls += 1
        if calls == 1 { throw MediaLoadError.httpFailure(detail: "transport/status-503") }
        return CoverMediaPayload(bytes: image, contentType: "image/jpeg")
    }
}
