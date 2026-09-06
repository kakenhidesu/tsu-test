// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import Foundation
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiReader
import TsuyomiUI
import XCTest

/// Renders screens to PNG so their layout can be looked at without a device.
///
/// This repository has no local toolchain and no device in the loop, so every layout mistake so far
/// has been found by a person installing a build and reporting it: actions floating in the middle of
/// a row, a control that was always visible when it should flash, two cards drawn as one. All of
/// those are visible in a still image. These are not assertions about pixels — there is no reference
/// to diff against, and one would only rot across Xcode versions. They are output: the images are
/// written for the CI job to publish, and the failures they catch are the ones a person catches by
/// looking.
///
/// What they cannot show: anything that only exists in motion or on real hardware — a transition's
/// timing, a gesture, Dynamic Type as the device is actually set, and how a material or a stroked
/// glyph resolves against a live backdrop. Those still need the device.
@MainActor
final class InterfaceSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The book screen, from the same offline fixture world the journey tests use, so what is drawn
    /// is a page the app really produced rather than a hand-made stand-in.
    func testBookScreenSnapshots() async throws {
        let world = try await FixtureWorld(directory: directory)
        let identity = try BookIdentity(sourceId: world.sourceId.value, remoteBookId: "1234")
        let model = BookModel(
            identity: identity,
            registry: world.registry,
            library: world.library,
            progressStore: world.progress
        )
        await model.load()
        guard case .content = model.state else {
            return XCTFail("detail did not load: \(model.state)")
        }
        for scheme in ColorScheme.allSnapshotCases {
            capture("book-detail-\(scheme.snapshotName)", scheme: scheme) {
                NavigationStack {
                    BookScreen(
                        model: model,
                        coverState: { .fallback(FallbackSpec(title: $0.title, sourceLabel: "Wenku8")) },
                        openChapter: { _ in }
                    )
                }
            }
        }
    }

    /// The reader's controls in the three states they have: away, up, and with the panel open.
    func testReaderChromeSnapshots() {
        let states: [(String, Bool, Bool)] = [("resting", false, false), ("controls", true, false)]
        for (name, visible, progress) in states {
            capture("reader-chrome-\(name)", scheme: .dark) {
                ReaderChromePreview(isVisible: visible, progressVisible: !progress)
            }
        }
    }

    func testReaderSettingsPanelSnapshots() {
        for scheme in ColorScheme.allSnapshotCases {
            capture("reader-settings-\(scheme.snapshotName)", scheme: scheme, height: 460) {
                ReaderSettingsPanelPreview()
            }
        }
    }

    private func capture(
        _ name: String,
        scheme: ColorScheme,
        width: CGFloat = 393,
        height: CGFloat = 852,
        @ViewBuilder content: () -> some View
    ) {
        // A solid ground under everything: the panels are drawn on materials, which composite against
        // whatever is behind them and render as nothing at all over an empty canvas.
        let renderer = ImageRenderer(
            content: ZStack {
                (scheme == .dark ? Color.black : Color.white).ignoresSafeArea()
                content()
            }
            .frame(width: width, height: height)
            .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else {
            return XCTFail("\(name) produced no image")
        }
        XCTAssertGreaterThan(data.count, 1_000, "\(name) rendered blank")
        let url = InterfaceSnapshotTests.outputDirectory.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(
                at: InterfaceSnapshotTests.outputDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }

    /// Beside the package, where the CI job collects them.
    static let outputDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("SnapshotOutput", isDirectory: true)
    }()
}

private extension ColorScheme {
    static var allSnapshotCases: [ColorScheme] { [.light, .dark] }

    var snapshotName: String { self == .dark ? "dark" : "light" }
}

/// The chrome needs a page under it to be judged against, so the preview draws one.
private struct ReaderChromePreview: View {
    let isVisible: Bool
    let progressVisible: Bool

    var body: some View {
        ZStack {
            ReaderTheme.paper.palette(for: .dark).background
            Text(String(repeating: "阅读器正文示例。", count: 40))
                .font(.system(size: 18))
                .foregroundStyle(ReaderTheme.paper.palette(for: .dark).foreground)
                .padding(24)
            ReaderChrome(
                chapterTitle: "第一章 雾中的灯塔",
                pageIndex: 60,
                pageCount: 125,
                isVisible: isVisible,
                progressVisible: progressVisible,
                actions: ReaderChromeActions(
                    onBack: {},
                    onPreviousChapter: {},
                    onNextChapter: {},
                    onOpenDirectory: {},
                    onOpenSettings: {},
                    onScrubBegin: {},
                    onScrub: { _ in },
                    onScrubEnd: { _ in }
                )
            )
        }
    }
}

private struct ReaderSettingsPanelPreview: View {
    @State private var settings = ReaderSettings()
    @State private var appearance = ColorSchemePreference.system

    var body: some View {
        ReaderSettingsSheet(
            settings: $settings,
            appearance: $appearance,
            onChange: { _ in },
            onClose: {}
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
