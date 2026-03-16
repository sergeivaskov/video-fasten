// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoFasten",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VideoFasten", targets: ["VideoFasten"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "VideoFasten",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
