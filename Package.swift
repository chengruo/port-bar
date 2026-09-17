// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "PortBar",
            targets: ["PortBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "PortBar",
            path: "Sources/PortBar"
        )
    ]
)
