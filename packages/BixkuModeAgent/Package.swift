// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BixkuModeAgent",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BixkuModeAgent", targets: ["BixkuModeAgent"]),
    ],
    dependencies: [
        .package(path: "../BixkuCore"),
        .package(path: "../BixkuDock"),
        .package(path: "../BixkuLLM"),
    ],
    targets: [
        .target(
            name: "BixkuModeAgent",
            dependencies: [
                .product(name: "BixkuCore", package: "BixkuCore"),
                .product(name: "BixkuDock", package: "BixkuDock"),
                .product(name: "BixkuLLM", package: "BixkuLLM"),
            ]
        ),
        .testTarget(
            name: "BixkuModeAgentTests",
            dependencies: [
                "BixkuModeAgent",
                .product(name: "BixkuLLM", package: "BixkuLLM"),
            ]
        ),
    ]
)
