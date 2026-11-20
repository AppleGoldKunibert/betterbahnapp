#!/bin/bash
# Runs BetterBahnKit's tests on Linux with the Android build's stand-ins (zlib instead of Compression,
# swift-crypto instead of CryptoKit, files instead of the Keychain), so the code paths only Android takes are
# tested too. Needs a Swift toolchain for Linux (the same as build.sh) and zlib's headers (zlib1g-dev).
#   Android/kit/test-linux.sh                      # all tests
#   Android/kit/test-linux.sh --filter ShareLink   # passes its arguments on to `swift test`
set -euo pipefail
K=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$K/../../Packages/BetterBahnKit" && pwd)
P="$K/.linux-test"
# The package's folders are linked fresh each time, so new Kit folders are picked up. It lives inside the
# repository, so tests finding the repository from their own path (asset catalog checks) still do.
rm -rf "$P/Sources" "$P/Tests" && mkdir -p "$P/Sources/BetterBahnKit" "$P/Tests"
for d in "$KIT/Sources/BetterBahnKit"/*/; do ln -s "$d" "$P/Sources/BetterBahnKit/$(basename "$d")"; done
ln -s "$K/CZlib" "$P/Sources/CZlib"
ln -s "$K/LinuxShims" "$P/Sources/BetterBahnKit/LinuxShims"
ln -s "$KIT/Tests/BetterBahnKitTests" "$P/Tests/BetterBahnKitTests"
cat > "$P/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.2
// Written by Android/kit/test-linux.sh.
import PackageDescription

let package = Package(
    name: "BetterBahnKitLinux",
    defaultLocalization: "de",
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "BetterBahnKit",
            dependencies: ["CZlib", .product(name: "Crypto", package: "swift-crypto")],
            exclude: ["Support/WorkerAuth.swift"],
            resources: [
                .copy("Resources/StationHints.json"), .copy("Resources/Ril100.json"), .copy("Resources/StationNames.json"),
                .copy("Resources/SeatMaps.json"), .copy("Resources/ExitSides.json"), .copy("Resources/ExitSideOverrides.json"),
                .copy("Resources/Platforms.json"), .process("Resources/Localizable.xcstrings"),
            ]
        ),
        .testTarget(
            name: "BetterBahnKitTests",
            dependencies: ["BetterBahnKit"],
            // App Attest only exists on Apple devices.
            exclude: ["WorkerAuthTests.swift"],
            resources: [.copy("Fixtures")],
            // Linux' URLProtocol isn't Sendable, which the tests' fakes subclass.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
MANIFEST
swift test --package-path "$P" "$@"
