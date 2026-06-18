// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Miner2049er",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "miner-2049er", targets: ["ZcashMetalMiner"])
    ],
    targets: [
        .executableTarget(
            name: "ZcashMetalMiner",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
