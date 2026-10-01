// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoClip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoClip", targets: ["AutoClip"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0")
    ],
    targets: [
        .executableTarget(
            name: "AutoClip",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/AutoClip",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
