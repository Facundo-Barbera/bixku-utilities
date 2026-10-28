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
    ],
    targets: [
        .executableTarget(
            name: "BixkuUtilities",
            dependencies: [
                .product(name: "BixkuCore", package: "BixkuCore"),
            ]
        ),
    ]
)
