// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterBahnKit",
    defaultLocalization: "de",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BetterBahnKit", targets: ["BetterBahnKit"]),
    ],
    targets: [
        .target(name: "BetterBahnKit", resources: [
            .copy("Resources/StationHints.json"), .copy("Resources/Ril100.json"), .copy("Resources/StationNames.json"),
            .copy("Resources/SeatMaps.json"), .copy("Resources/ExitSides.json"), .copy("Resources/ExitSideOverrides.json"),
            .copy("Resources/Platforms.json"), .process("Resources/Localizable.xcstrings"),
        ]),
        .testTarget(
            name: "BetterBahnKitTests",
            dependencies: ["BetterBahnKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
