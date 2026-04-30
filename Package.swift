// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GOLP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "GOLP",
            targets: ["GOLP"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GOLP",
            exclude: ["Info.plist"]
        )
    ]
)
