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
        .library(name: "ReTiCAKeychain", targets: ["ReTiCAKeychain"]),
        // The live Meshtastic driver (spec 2026-10-16 Contract 2). The ONLY ReTiCA code that
        // imports MeshtasticKit.
        .library(name: "ReTiCAMeshtasticLive", targets: ["ReTiCAMeshtasticLive"]),
        // The live MeshCore driver (spec 2026-11-07 Contract 2). The ONLY ReTiCA code that
        // imports MeshCoreKit.
        .library(name: "ReTiCAMeshCoreLive", targets: ["ReTiCAMeshCoreLive"]),
        // The live RNode driver (spec 2026-11-08 Contract 2). The ONLY ReTiCA library code
        // that imports RNodeKit (tests import it too).
        .library(name: "ReTiCARNodeLive", targets: ["ReTiCARNodeLive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
        .package(path: "../FCB"),
        .package(path: "../MeshtasticKit"),
        .package(path: "../MeshCoreKit"),
        .package(path: "../RNodeKit"),
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
        .target(
            name: "ReTiCAMeshtasticLive",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "ReTiCAMeshCoreLive",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "MeshCoreKit", package: "MeshCoreKit"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "ReTiCARNodeLive",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "RNodeKit", package: "RNodeKit"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCATests",
            dependencies: ["ReTiCA"],
            resources: [.process("Vectors/fixtures.json"), .process("Vectors/lxmf_fixtures.json"), .process("Vectors/lxmf_propagation_fixtures.json"), .process("Vectors/lxmf_rich_fixtures.json"), .process("Vectors/lxmf_stamp_fixtures.json"), .process("Vectors/lxmf_peering_fixtures.json"), .process("Vectors/lxmf_pn_announce_fixtures.json"), .process("Vectors/msgpack_signed_fixtures.json"), .process("Vectors/lxmf_signed_fixtures.json"), .process("Vectors/lxmf_announce_fixtures.json"), .process("Vectors/lxmf_stamped_announce_fixtures.json"), .process("Vectors/network_stamp_fixtures.json"), .process("Vectors/stamped_announce_packet_fixtures.json"), .process("Vectors/lxmf_ticket_fixtures.json"), .process("Vectors/lxmf_fractional_stamp_fixtures.json"), .process("Vectors/lxmf_fractional_cost_app_data_fixtures.json"), .process("Vectors/lxmf_pn_offer_limits_fixtures.json")]
        ),
        .testTarget(
            name: "ReTiCAInterfacesTests",
            dependencies: [
                "ReTiCAInterfaces",
                // The live Meshtastic tests drive CoreBluetoothMock, which is process-global: they
                // live in THIS target, nested in the serialized `FCBDriverAdapterCBMTests`, so they
                // never overlap the BLE adapter's CBM tests.
                "ReTiCAMeshtasticLive",
                "ReTiCAMeshCoreLive",
                "ReTiCARNodeLive",
                .product(name: "RNodeKit", package: "RNodeKit"),
                .product(name: "RNodeMock", package: "RNodeKit"),
                .product(name: "MeshCoreKit", package: "MeshCoreKit"),
                .product(name: "MeshCoreMock", package: "MeshCoreKit"),
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "MeshtasticMock", package: "MeshtasticKit"),
                .product(name: "MeshProto", package: "MeshtasticKit"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ],
            resources: [.process("Vectors/ble_fixtures.json"), .process("Vectors/meshtastic_fixtures.json"), .process("Vectors/meshtastic_our_split.json"), .process("Vectors/meshcore_fixtures.json"), .process("Vectors/meshcore_our_split.json")]
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
            resources: [.process("Vectors/transport_fixtures.json"), .process("Vectors/proof_fixtures.json"), .process("Vectors/stamped_announce_packet_fixtures.json"),
                        .process("Vectors/path_request_fixtures.json"), .process("Vectors/destination_stamp_fixtures.json"),
                        .process("Vectors/link_request_stamp_fixtures.json"), .process("Vectors/peer_ratchet_fixtures.json"),
                        .process("Vectors/own_ratchet_fixtures.json")]
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
            ],
            resources: [.process("Vectors/stamped_announce_packet_fixtures.json")]
        ),
        // Shared per-device identity storage (Keychain access group). Depends only on the
        // dependency-free core so any app can adopt it without pulling in TCA or transports.
        .target(
            name: "ReTiCAKeychain",
            dependencies: ["ReTiCA"]
        ),
        .testTarget(
            name: "ReTiCAKeychainTests",
            dependencies: ["ReTiCAKeychain", "ReTiCA"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
