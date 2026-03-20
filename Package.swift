// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwakeSequoia",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AwakeSequoia",
            path: "Sources",
            exclude: ["Shaders.metal"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ModelIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox"),
            ]
        )
    ]
)
