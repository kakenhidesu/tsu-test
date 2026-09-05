// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "Tsuyomi",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("16.4")],
    products: [
        .library(name: "TsuyomiProtocol", targets: ["TsuyomiProtocol"]),
        .library(name: "TsuyomiCore", targets: ["TsuyomiCore"]),
        .library(name: "TsuyomiSource", targets: ["TsuyomiSource"]),
        .library(name: "TsuyomiReader", targets: ["TsuyomiReader"]),
        .library(name: "TsuyomiUI", targets: ["TsuyomiUI"])
    ],
    targets: [
        .target(name: "TsuyomiProtocol"),
        .testTarget(name: "TsuyomiProtocolTests", dependencies: ["TsuyomiProtocol"]),

        .target(name: "TsuyomiCore", dependencies: ["TsuyomiProtocol"]),
        .testTarget(name: "TsuyomiCoreTests", dependencies: ["TsuyomiCore"]),

        .target(
            name: "CQuickJS",
            exclude: [
                "quickjs-ng/LICENSE",
                "quickjs-ng/UPSTREAM.md"
            ],
            sources: [
                "tsuyomi_quickjs_bridge.c",
                "quickjs-ng/quickjs.c",
                "quickjs-ng/dtoa.c",
                "quickjs-ng/libregexp.c",
                "quickjs-ng/libunicode.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("quickjs-ng"),
                .define("_GNU_SOURCE"),
                // Vendored upstream source is never hand-edited, so its own diagnostics are silenced
                // here rather than by touching the files (see quickjs-ng/UPSTREAM.md).
                .unsafeFlags(["-w"])
            ]
        ),
        .target(name: "TsuyomiSource", dependencies: ["CQuickJS", "TsuyomiCore", "TsuyomiProtocol"]),
        .testTarget(name: "TsuyomiSourceTests", dependencies: ["TsuyomiSource", "TsuyomiCore"]),

        .target(name: "TsuyomiReader", dependencies: ["TsuyomiCore", "TsuyomiProtocol"]),
        .testTarget(name: "TsuyomiReaderTests", dependencies: ["TsuyomiReader"]),

        .target(name: "TsuyomiUI", dependencies: ["TsuyomiCore", "TsuyomiProtocol"])
    ]
)
