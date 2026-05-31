// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftCardanoWallet",
    platforms: [
        .macOS(.v15)
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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.4.4"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-chain.git", from: "0.5.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-txbuilder.git", from: "1.0.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-txvalidator.git", from: "0.2.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-utils.git", from: "0.5.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-cips.git", from: "0.3.3"),
        .package(url: "https://github.com/Kingpin-Apps/swift-handles-api.git", from: "0.1.1"),
        .package(url: "https://github.com/Kingpin-Apps/swift-gnupg.git", from: "0.1.3"),
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
                .product(name: "SwiftCardanoUtils", package: "swift-cardano-utils"),
                .product(name: "SwiftCardanoCIPs", package: "swift-cardano-cips"),
                .product(name: "SwiftHandlesAPI", package: "swift-handles-api"),
                .product(name: "GnuPG", package: "swift-gnupg"),
                .product(name: "SwiftMnemonic", package: "swift-mnemonic"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "SQLite", package: "SQLite.swift", condition: .when(traits: ["SQLite"])),
            ],
            swiftSettings: [
                .define("WALLET_HAS_SQLITE", .when(traits: ["SQLite"])),
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
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
