// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenLiveWalls",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "OpenLiveWalls",
            dependencies: [],
            path: "Sources"
        )
    ]
)
