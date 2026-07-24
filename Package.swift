// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoreBar",
    platforms: [
        .macOS("26.0"),
    ],
    targets: [
        .executableTarget(
            name: "MoreBar",
            path: "Sources/MoreBar"
        ),
    ]
)
