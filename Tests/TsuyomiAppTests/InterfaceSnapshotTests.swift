// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import Foundation
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiReader
import TsuyomiUI
import UIKit
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
    /// The scratch directory is made inside the test rather than in `setUp`: those overrides are not
    /// main-actor isolated, and this case is, so they cannot touch its state.
    private func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The book screen, from the same offline fixture world the journey tests use, so what is drawn
    /// is a page the app really produced rather than a hand-made stand-in.
    func testBookScreenSnapshots() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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

    /// Drawn from a real window rather than with `ImageRenderer`. That renderer only knows how to draw
    /// what SwiftUI itself lays out: anything backed by UIKit — a `List`, a `Menu` — comes out as a
    /// "not supported" placeholder, which is how the first run produced a book screen that was one
    /// yellow sign, and two appearances of it byte for byte identical.
    private func capture(
        _ name: String,
        scheme: ColorScheme,
        width: CGFloat = 393,
        height: CGFloat = 852,
        @ViewBuilder content: () -> some View
    ) {
        let size = CGSize(width: width, height: height)
        // A solid ground under everything: these panels are drawn on materials, which composite with
        // whatever is behind them and come out as nothing at all over an empty canvas.
        let controller = UIHostingController(
            rootView: ZStack {
                (scheme == .dark ? Color.black : Color.white).ignoresSafeArea()
                content()
            }
        )
        controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = controller.overrideUserInterfaceStyle
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // SwiftUI commits its layout on the next run-loop pass, so a snapshot taken in the same turn
        // catches the view before it has one.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // The layer tree, not `drawHierarchy`: that one needs the render server to have presented the
        // window, which never happens in a test, and it does not fail — it hands back a blank image.
        // Core Animation will not draw a `UIVisualEffectView`, so a material reads as nothing here
        // while everything laid out on top of it still renders, which is what these images are for.
        let image = UIGraphicsImageRenderer(size: size).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        guard let data = image.pngData() else {
            return XCTFail("\(name) produced no image")
        }
        // A blank page is small but not tiny, so file size proves nothing: a white 393×852 PNG is
        // 15 KB. Count what is actually on it instead — a screen with content has many distinct
        // colours, and every renderer that quietly failed so far produced one or two.
        XCTAssertGreaterThan(
            InterfaceSnapshotTests.distinctColours(in: image),
            8,
            "\(name) rendered blank or near-blank"
        )
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

    /// Samples the image down to a small grid and counts the distinct pixels in it. Cheap, and enough
    /// to tell a rendered screen from a flat one without knowing what the screen should look like.
    private static func distinctColours(in image: UIImage) -> Int {
        guard let source = image.cgImage else { return 0 }
        let width = 40
        let height = 80
        var pixels = [UInt32](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Set(pixels).count
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
