// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BixkuUtilities",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BixkuUtilities", targets: ["BixkuUtilities"]),
    ],
    dependencies: [
        .package(path: "../../packages/BixkuCore"),
        .package(path: "../../packages/BixkuDock"),
        .package(path: "../../packages/BixkuNotify"),
        .package(path: "../../packages/BixkuDockSettings"),
        .package(path: "../../packages/BixkuLLM"),
        .package(path: "../../packages/BixkuModeAgent"),
        // Auto-updates. EXACT pinned version: must match release/sparkle.version (checked by a test).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "BixkuUtilities",
            dependencies: [
                .product(name: "BixkuCore", package: "BixkuCore"),
                .product(name: "BixkuDock", package: "BixkuDock"),
                .product(name: "BixkuNotify", package: "BixkuNotify"),
                .product(name: "BixkuDockSettings", package: "BixkuDockSettings"),
                .product(name: "BixkuLLM", package: "BixkuLLM"),
                .product(name: "BixkuModeAgent", package: "BixkuModeAgent"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "BixkuUtilitiesTests",
            dependencies: [
                "BixkuUtilities",
                .product(name: "BixkuDock", package: "BixkuDock"),
                .product(name: "BixkuLLM", package: "BixkuLLM"),
                .product(name: "BixkuModeAgent", package: "BixkuModeAgent"),
            ]
        ),
    ]
)
