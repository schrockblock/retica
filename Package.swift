// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReTiCA",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "ReTiCA", targets: ["ReTiCA"]),
        .library(name: "ReTiCAInterfaces", targets: ["ReTiCAInterfaces"]),
        .library(name: "ReTiCATransport", targets: ["ReTiCATransport"]),
        .library(name: "ReTiCANode", targets: ["ReTiCANode"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
        .package(path: "../FCB"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", from: "1.0.0"),
        .package(url: "https://github.com/leif-ibsen/SwiftEdDSA", exact: "4.1.0"),
    ],
    targets: [
        .target(name: "ReTiCA"),
        .target(name: "Cbzip2"),
        .target(
            name: "ReTiCAInterfaces",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
        .testTarget(
            name: "ReTiCATests",
            dependencies: ["ReTiCA"],
            resources: [.process("Vectors/fixtures.json"), .process("Vectors/lxmf_fixtures.json"), .process("Vectors/lxmf_propagation_fixtures.json"), .process("Vectors/lxmf_rich_fixtures.json"), .process("Vectors/lxmf_stamp_fixtures.json"), .process("Vectors/lxmf_peering_fixtures.json"), .process("Vectors/lxmf_pn_announce_fixtures.json"), .process("Vectors/msgpack_signed_fixtures.json"), .process("Vectors/lxmf_signed_fixtures.json")]
        ),
        .testTarget(
            name: "ReTiCAInterfacesTests",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ],
            resources: [.process("Vectors/ble_fixtures.json")]
        ),
        .target(
            name: "ReTiCATransport",
            dependencies: [
                "ReTiCA",
                "Cbzip2",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SwiftEdDSA", package: "SwiftEdDSA"),
            ]
        ),
        .testTarget(
            name: "ReTiCATransportTests",
            dependencies: [
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Vectors/transport_fixtures.json")]
        ),
        .target(
            name: "ReTiCANode",
            dependencies: [
                "ReTiCAInterfaces",
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCANodeTests",
            dependencies: [
                "ReTiCANode",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
