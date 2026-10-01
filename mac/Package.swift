// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacScreenServer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacScreenServer", targets: ["MacScreenServer"]),
        .executable(name: "MacScreenApp", targets: ["MacScreenApp"])
    ],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ScreenCore",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/ScreenCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "MacScreenServer",
            dependencies: ["ScreenCore", "VirtualDisplayBridge"],
            path: "Sources/MacScreenServer"
        ),
        .executableTarget(
            name: "MacScreenApp",
            dependencies: ["ScreenCore", "VirtualDisplayBridge"],
            path: "Sources/MacScreenApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
