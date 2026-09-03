// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReviewBar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReviewBarKit", targets: ["ReviewBarKit"]),
        .executable(name: "ReviewBar", targets: ["ReviewBar"]),
    ],
    targets: [
        .target(name: "ReviewBarKit"),
        .executableTarget(name: "ReviewBar", dependencies: ["ReviewBarKit"]),
        .testTarget(name: "ReviewBarKitTests", dependencies: ["ReviewBarKit"]),
    ]
)
