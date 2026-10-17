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
        .package(url: "https://github.com/schwa/MetalSprockets", .upToNextMinor(from: "0.2.3")),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", .upToNextMinor(from: "0.4.1")),
        .package(url: "https://github.com/schwa/MetalSupport", .upToNextMinor(from: "1.0.7")),
        .package(url: "https://github.com/schwa/SwiftMesh", .upToNextMinor(from: "0.0.10")),
        .package(url: "https://github.com/schwa/GeometryLite3D", .upToNextMinor(from: "0.2.4")),
        .package(url: "https://github.com/schwa/GoldenImage", .upToNextMinor(from: "0.1.6"))
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
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "GoldenImage", package: "GoldenImage")
            ],
            resources: [
                .copy("GoldenImages")
            ]
        )
    ]
)
