// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EdgeBar", targets: ["EdgeBar"])
    ],
    targets: [
        .executableTarget(
            name: "EdgeBar",
            path: "Sources/EdgeBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
