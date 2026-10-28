// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BixkuDock",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BixkuDock", targets: ["BixkuDock"]),
    ],
    dependencies: [
        .package(path: "../BixkuCore"),
    ],
    targets: [
        .target(
            name: "BixkuDock",
            dependencies: [
                .product(name: "BixkuCore", package: "BixkuCore"),
            ]
        ),
        .testTarget(name: "BixkuDockTests", dependencies: ["BixkuDock"]),
    ]
)
