// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CommandHub",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CommandHub", targets: ["CommandHub"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1")
    ],
    targets: [
        .executableTarget(
            name: "CommandHub",
            dependencies: [
                .product(name: "HotKey", package: "HotKey")
            ]
        )
    ]
)
