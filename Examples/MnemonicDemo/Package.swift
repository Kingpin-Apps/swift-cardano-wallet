// swift-tools-version: 6.3
import PackageDescription

/// Minimal SwiftUI demo for `swift-cardano-wallet`.
///
/// Run with: `swift run MnemonicDemo`
///
/// Drops you in a single-window app that asks for a mnemonic, talks to Koios for the
/// chain, and shows the wallet's first receive address + balance. Send / sign flows are
/// not wired up — this is a viewer to verify your setup compiles + connects.
let package = Package(
    name: "MnemonicDemo",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Local path to the parent package — adjust if you copy this example elsewhere.
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "MnemonicDemo",
            dependencies: [
                .product(name: "SwiftCardanoWallet", package: "swift-cardano-wallet")
            ]
        )
    ]
)
