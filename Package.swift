// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloraTrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FloraTrace", targets: ["FloraTrace"])
    ],
    targets: [
        .executableTarget(
            name: "FloraTrace",
            path: "Sources/FloraTrace"
        )
    ]
)
