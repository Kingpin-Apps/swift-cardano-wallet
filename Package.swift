// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoWallet",
    platforms: [
        .macOS(.v15),
        .iOS(.v18), // declare the (already-effective, via txvalidator/ConfigurationTOML) iOS floor
    ],
    products: [
        .library(
            name: "SwiftCardanoWallet",
            targets: ["SwiftCardanoWallet"]
        ),
    ],
    traits: [
        .trait(
            name: "SQLite",
            description: "Adds SQLiteUTxOStore for persistent UTxO caching (pulls in SQLite.swift)."
        ),
        .trait(
            name: "Hardware",
            description: "Hardware-wallet support (Ledger/Trezor via cardano-hw-cli). Pulls SwiftCardanoUtils' CLITools (subprocess) — macOS/Linux only. Off by default; consumers that enable it must also enable SwiftCardanoUtils' CLITools trait."
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.5.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.7.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-txbuilder.git", from: "1.0.3"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-txvalidator.git", from: "0.2.2"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-utils.git", from: "0.5.5"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-cips.git", from: "0.3.3"),
        .package(url: "https://github.com/Kingpin-Apps/swift-handles-api.git", from: "0.1.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-mnemonic.git", from: "0.2.5"),
        // SQLite backend for SQLiteUTxOStore. Only linked when the `SQLite` package trait is enabled.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
    ],
    targets: [
        .target(
            name: "SwiftCardanoWallet",
            dependencies: [
                .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
                .product(name: "SwiftCardanoChain", package: "swift-cardano-chain"),
                .product(name: "SwiftCardanoTxBuilder", package: "swift-cardano-txbuilder"),
                .product(name: "SwiftCardanoTxValidator", package: "swift-cardano-txvalidator"),
                // Only needed for the hardware-wallet path (CardanoHWCLI). Gated so an iOS/slim
                // wallet build excludes SwiftCardanoUtils' CLI/Command surface entirely.
                .product(name: "SwiftCardanoUtils", package: "swift-cardano-utils", condition: .when(traits: ["Hardware"])),
                .product(name: "SwiftCardanoCIPs", package: "swift-cardano-cips"),
                .product(name: "SwiftHandlesAPI", package: "swift-handles-api"),
                .product(name: "SwiftMnemonic", package: "swift-mnemonic"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SQLite", package: "SQLite.swift", condition: .when(traits: ["SQLite"])),
            ],
            swiftSettings: [
                .define("WALLET_HAS_SQLITE", .when(traits: ["SQLite"])),
                .define("HARDWARE", .when(traits: ["Hardware"])),
            ]
        ),
        .testTarget(
            name: "SwiftCardanoWalletTests",
            dependencies: ["SwiftCardanoWallet"],
            resources: [
                .copy("data"),
            ],
            swiftSettings: [
                .define("WALLET_HAS_SQLITE", .when(traits: ["SQLite"])),
                .define("HARDWARE", .when(traits: ["Hardware"])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
