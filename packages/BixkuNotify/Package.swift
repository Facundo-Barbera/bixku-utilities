// swift-tools-version:5.9
import PackageDescription

// Portable (Foundation only) notification-input logic for the Dock module:
// the `bixku://notify` URL scheme (parse, validate, build), the `bixku-notify` command
// line helper, and the content of the end-of-mode digest notification.
// The AppKit / UserNotifications glue lives in apps/mac.
let package = Package(
    name: "BixkuNotify",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BixkuNotify", targets: ["BixkuNotify"]),
        .executable(name: "bixku-notify", targets: ["BixkuNotifyCLI"]),
    ],
    dependencies: [
        .package(path: "../BixkuDock"),
    ],
    targets: [
        .target(
            name: "BixkuNotify",
            dependencies: [
                .product(name: "BixkuDock", package: "BixkuDock"),
            ]
        ),
        .executableTarget(
            name: "BixkuNotifyCLI",
            dependencies: ["BixkuNotify"]
        ),
        .testTarget(name: "BixkuNotifyTests", dependencies: ["BixkuNotify"]),
    ]
)
