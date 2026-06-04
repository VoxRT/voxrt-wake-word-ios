// swift-tools-version: 5.9
//
// VoxrtWakeWord — always-on wake-phrase detection on the VoxRT
// custom inference runtime (https://voxrt.com). 8-block depthwise-
// separable Conv1D, ~48 K parameters, ~100 KB fp16 weights. Mirrors
// the Android `voxrt-wake-word-android` JitPack artefact.
//
// This file is generated per-release from the VoxRT monorepo. Do not
// edit by hand — changes here are clobbered on the next cut.

import PackageDescription

let package = Package(
    name: "VoxrtWakeWord",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "VoxrtWakeWord",
            targets: ["VoxrtWakeWord"]
        ),
    ],
    targets: [
        .target(
            name: "VoxrtWakeWord",
            dependencies: ["VoxrtWakeWordNative"],
            path: "Sources/VoxrtWakeWord"
        ),
        .binaryTarget(
            name: "VoxrtWakeWordNative",
            url: "https://github.com/VoxRT/voxrt-wake-word-ios/releases/download/v0.1.0/VoxrtWakeWordNative.xcframework.zip",
            checksum: "47bfb2deda6dd9e5078d8fd9bc6a2203811cd509b86b6d86dd90c272113ac5b5"
        ),
    ]
)
