// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BixkuDockSettings",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BixkuDockSettings", targets: ["BixkuDockSettings"]),
    ],
    dependencies: [
        .package(path: "../BixkuDock"),
    ],
    targets: [
        .target(
            name: "BixkuDockSettings",
            dependencies: [
                .product(name: "BixkuDock", package: "BixkuDock"),
            ]
        ),
        .testTarget(name: "BixkuDockSettingsTests", dependencies: ["BixkuDockSettings"]),
    ]
)
