// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MetalSprocketsPBR",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "MetalSprocketsPBR", targets: ["MetalSprocketsPBR"]),
        .library(name: "MetalSprocketsPBRShaders", targets: ["MetalSprocketsPBRShaders"])
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.2.2"),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", from: "0.3.0"),
        .package(url: "https://github.com/schwa/MetalSupport", branch: "main"),
        .package(url: "https://github.com/schwa/SwiftMesh", branch: "main"),
        .package(url: "https://github.com/schwa/GeometryLite3D", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "MetalSprocketsPBRShaders",
            dependencies: [
                .product(name: "MetalSprocketsShaders", package: "MetalSprockets")
            ],
            exclude: ["Metal"],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ]
        ),
        .target(
            name: "MetalSprocketsPBR",
            dependencies: [
                "MetalSprocketsPBRShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "MetalSupport", package: "MetalSupport"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D")
            ]
        ),
        .testTarget(
            name: "MetalSprocketsPBRTests",
            dependencies: [
                "MetalSprocketsPBR",
                "MetalSprocketsPBRShaders",
                .product(name: "SwiftMesh", package: "SwiftMesh")
            ]
        )
    ]
)
