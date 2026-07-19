// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReTiCA",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .macCatalyst(.v16),
    ],
    products: [
        .library(name: "ReTiCA", targets: ["ReTiCA"]),
        .library(name: "ReTiCAInterfaces", targets: ["ReTiCAInterfaces"]),
        .library(name: "ReTiCATransport", targets: ["ReTiCATransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
    ],
    targets: [
        .target(name: "ReTiCA"),
        .target(
            name: "ReTiCAInterfaces",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCATests",
            dependencies: ["ReTiCA"],
            resources: [.process("Vectors/fixtures.json")]
        ),
        .testTarget(
            name: "ReTiCAInterfacesTests",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "ReTiCATransport",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCATransportTests",
            dependencies: [
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
