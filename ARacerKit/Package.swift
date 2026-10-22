// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ARacerKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ARacerKit", targets: ["ARacerKit"]),
        .executable(name: "aracer-cli", targets: ["aracer-cli"]),
        .executable(name: "ARacerDash", targets: ["ARacerDash"]),
    ],
    targets: [
        .target(name: "ARacerKit", resources: [.copy("table_catalog.json")]),
        .executableTarget(name: "aracer-cli", dependencies: ["ARacerKit"]),
        .executableTarget(name: "ARacerDash", dependencies: ["ARacerKit"]),
        .testTarget(name: "ARacerKitTests", dependencies: ["ARacerKit"], resources: [.copy("table_catalog.json")]),
    ]
)
