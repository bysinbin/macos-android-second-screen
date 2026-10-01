// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacScreenServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacScreenServer", targets: ["MacScreenServer"])
    ],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MacScreenServer",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/MacScreenServer",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network")
            ]
        ),
    ]
)
