# SwiftCardanoWallet

A high-level Swift wallet SDK for [Cardano](https://cardano.org). Pure Swift —
composes the [`swift-cardano-*`](https://github.com/Kingpin-Apps) package.
For macOS / iOS / Linux.

```swift
import SwiftCardanoWallet

let wallet = try await MnemonicWallet(
    mnemonic: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet…")
)
let txid = try await wallet.send(lovelace: 5_000_000, to: address)
```

## Features

- **Six wallet types** — mnemonic, TextEnvelope (`cardano-cli` `.skey`), watch-only,
  passphrase-encrypted, native-script multisig, and hardware (Ledger / Trezor via
  `cardano-hw-cli`).
- **All major operations** — send, stake (register / delegate / withdraw), mint
  (native script + CIP-25 v1 NFTs), Conway-era governance (DRep registration, vote
  delegation, voting). Auto coin selection, auto signing, auto submit.
- **Five chain providers** — Blockfrost, Koios, Ogmios, Kupo, Offline. Pluggable via
  `ProviderConfig`.
- **CIP support** — CIP-1852 (HD), CIP-8 (message signing), CIP-14 (asset
  fingerprints), CIP-25 v1 (NFT metadata), CIP-30 (dApp connector via
  `CIP30Provider`), CIP-119 (DRep metadata).
- **ADA Handle resolution** — `wallet.sendTo(handle: "$alice", lovelace: 5_000_000)`
  via `swift-handles-api` with a TTL cache.
- **Two storage backends** — `FileKeyStore` (default) and `KeychainKeyStore`
  (Apple platforms). Optional `SQLiteUTxOStore` behind the `SQLite` package trait.
- **Sample SwiftUI app** in [`Examples/MnemonicDemo/`](Examples/MnemonicDemo/).

## Install

In your `Package.swift`:

```swift
.package(url: "https://github.com/Kingpin-Apps/swift-cardano-wallet.git", from: "0.1.0"),
```

Then add `"SwiftCardanoWallet"` to your target's dependencies.

To enable the optional SQLite-backed UTxO cache:

```swift
.package(
    url: "https://github.com/Kingpin-Apps/swift-cardano-wallet.git",
    from: "0.1.0",
    traits: ["SQLite"]
),
```

## Five lines to send ADA

```swift
import SwiftCardanoWallet

let wallet = try await MnemonicWallet(
    mnemonic: phrase,
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet…")
)
let txId = try await wallet.send(lovelace: 5_000_000, to: try Address.fromBech32("addr1…"))
```

For a step-by-step walkthrough — including how to inspect the unsigned transaction before
signing — see the [Quick Start article](Sources/SwiftCardanoWallet/SwiftCardanoWallet.docc/Articles/QuickStart.md).

## Wallet types

| Type | When to use |
|---|---|
| `MnemonicWallet` | BIP-39 phrase. The default; HD addresses + auto sign. |
| `EncryptedKeyManager` (wraps Mnemonic) | Persist a passphrase-encrypted blob. PBKDF2-SHA512 → AES-256-GCM. |
| `TextEnvelopeKeyManager` | Existing `cardano-cli` `.skey` files. |
| `WatchOnlyKeyManager` | Public keys / addresses only. Useful for monitoring. |
| `MultisigWallet` | Native-script multisig (N-of-M, all, any). Coordinator collects partial witnesses from cosigners and assembles. |
| `HardwareWallet` | Ledger / Trezor via `cardano-hw-cli`. macOS + Linux only (iOS traps with `unsupportedOperation`). |

See the [Wallet Types article](Sources/SwiftCardanoWallet/SwiftCardanoWallet.docc/Articles/WalletTypes.md)
for construction examples and trade-offs.

## Operations cheat sheet

```swift
// Read
let balance = try await wallet.balance()        // ADA + multi-asset + rewards
let address = try await wallet.receiveAddress()
let utxos   = try await wallet.utxos()

// Send
try await wallet.send(lovelace: 5_000_000, to: addr)
try await wallet.sendTo(handle: "$alice", lovelace: 5_000_000)

// Stake
try await wallet.registerStake()
try await wallet.delegate(toPool: poolId)
try await wallet.claimAllRewards()

// Mint (native script policy + CIP-25 v1 NFT)
try await wallet.mintNFT(metadata: cip25, policy: policy)

// Governance
try await wallet.delegateVote(to: .alwaysAbstain)
try await wallet.vote(on: govActionId, vote: .yes)
```

For multi-action transactions, build with `prepareSend(...)` / `prepareDelegate(...)` etc.
and chain the `PreparedTransaction`s manually — see the [Operations article](Sources/SwiftCardanoWallet/SwiftCardanoWallet.docc/Articles/Operations.md).

## Documentation

DocC catalog ships in [`Sources/SwiftCardanoWallet/SwiftCardanoWallet.docc/`](Sources/SwiftCardanoWallet/SwiftCardanoWallet.docc/).
Open the package in Xcode and choose **Product → Build Documentation** (⌃⇧⌘D) — this is
the canonical path; Xcode's symbol extractor handles the OpenSSL transitive dependency
(via `swift-cardano-chain` → Blockfrost) without extra wiring.

For command-line generation, add the [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin)
to your own consumer package and run `swift package generate-documentation`. (Adding it
here causes `swift-symbolgraph-extract` to fail on the OpenSSL XCFramework on macOS, so
it isn't a direct dep.)

## Status

Currently at parity with [TokeoPay/CardanoKit](https://github.com/TokeoPay/CardanoKit) plus
the full `swift-cardano-txbuilder` shortcut surface. **163 hermetic tests
(170 with the SQLite trait) — all green.**

See [`.agents/PLAN.md`](.agents/PLAN.md) for the full build sequence, dependencies, and
known follow-ups (Plutus minting, CIP-25 v2, Ogmios chain-sync, mixed software/hardware
signing).

## Requirements

- Swift 6.3+
- macOS 15+ / iOS 18+ / Linux (Swift 6 toolchain)
- Hardware wallet support requires `cardano-hw-cli` installed locally (`scm install
  cardano-hw-cli` from `swift-cardano-multitool`, or the upstream Vacuumlabs binary)

## License

Apache 2.0 — see [LICENSE](LICENSE).
