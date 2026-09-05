// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "Tsuyomi",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("16.4")],
    products: [
        .library(name: "TsuyomiProtocol", targets: ["TsuyomiProtocol"])
    ],
    targets: [
        .target(name: "TsuyomiProtocol"),
        .testTarget(name: "TsuyomiProtocolTests", dependencies: ["TsuyomiProtocol"])
    ]
)
