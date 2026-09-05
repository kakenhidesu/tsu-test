// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "Tsuyomi",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("16.4")],
    products: [
        .library(name: "TsuyomiProtocol", targets: ["TsuyomiProtocol"]),
        .library(name: "TsuyomiCore", targets: ["TsuyomiCore"])
    ],
    targets: [
        .target(name: "TsuyomiProtocol"),
        .testTarget(name: "TsuyomiProtocolTests", dependencies: ["TsuyomiProtocol"]),

        .target(name: "TsuyomiCore", dependencies: ["TsuyomiProtocol"]),
        .testTarget(name: "TsuyomiCoreTests", dependencies: ["TsuyomiCore"])
    ]
)
