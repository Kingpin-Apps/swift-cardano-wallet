# SwiftCardanoWallet

A high-level Swift wallet SDK for [Cardano](https://cardano.org). Pure Swift —
composes the [`swift-cardano-*`](https://github.com/Kingpin-Apps) package.
For macOS / iOS / Linux.

```swift
import SwiftCardanoWallet

let wallet = try await Wallet.mnemonic(
    phrase: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet…")
)
let txid = try await wallet.send(lovelace: 5_000_000, to: address)
```

`Wallet` is an enum that unifies all wallet kinds (`mnemonic`, `textEnvelope`, `watchOnly`,
`multisig`, `hardware`) behind one `Sendable` value. Six labeled factory methods
(`Wallet.mnemonic(phrase:...)`, `Wallet.encrypted(blob:passphrase:...)`,
`Wallet.textEnvelope(paymentKeyFile:...)`, `Wallet.watchOnly(...)`, `Wallet.multisig(...)`,
`Wallet.hardware(...)`) cover every supported construction. Common reads — `kind`,
`network`, `primaryAddress()`, `utxos()`, `balance()`, `canSign` — dispatch automatically.
For richer flows, extract the concrete actor via `wallet.mnemonicWallet`,
`wallet.textEnvelopeWallet`, `wallet.watchOnlyWallet`, `wallet.multisigWallet`,
`wallet.hardwareWallet`.

> **Why six factories but five cases?** "Encrypted" is a key-management concern, not a
> runtime distinction — `Wallet.encrypted(blob:passphrase:...)` decrypts and returns a
> `.mnemonic(_:)` case, because once decrypted there's no runtime difference between a
> mnemonic loaded from a phrase and one recovered from an `EncryptedBlob`.

## Features

- **Six wallet types** — mnemonic, TextEnvelope (`cardano-cli` `.skey`), watch-only,
  passphrase-encrypted, native-script multisig, and hardware (Ledger / Trezor via
  `cardano-hw-cli`).
- **All major operations** — send, stake (register / delegate / withdraw), mint
  (**both** native-script and Plutus V1/V2/V3 policies, with CIP-25 v1 + v2 NFTs),
  Conway-era governance (DRep registration, vote delegation, voting). Auto coin
  selection, auto signing, auto submit, auto collateral selection for Plutus mints.
- **Five chain providers** — Blockfrost, Koios, Ogmios, Kupo, Offline. Pluggable via
  `ProviderConfig`.
- **CIP support** — CIP-1852 (HD), CIP-8 (message signing), CIP-14 (asset
  fingerprints), CIP-25 v1 + v2 (NFT metadata; v2 supports byte-keyed asset names for
  CIP-67/68 prefixed assets), CIP-30 (dApp connector via
  `wallet.cip30Provider(info:policy:)` — every signing op is gated on a required
  `CIP30ApprovalPolicy`), CIP-119 (DRep metadata).
- **ADA Handle resolution** — `wallet.sendTo(handle: "$alice", lovelace: 5_000_000)`
  via `swift-handles-api` with a TTL cache.
- **Two storage backends** — `FileKeyStore` (default) and `KeychainKeyStore`
  (Apple platforms). Optional `SQLiteUTxOStore` behind the `SQLite` package trait.

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

## Generating a new wallet

Every constructor on this page takes existing key material. To mint a fresh wallet,
use the matching `generate(...)` factory:

```swift
// HD mnemonic — the default. Returns the freshly-minted phrase; persist or display
// it to the user before this tuple goes out of scope — once it's gone, the keys are
// unrecoverable.
let (wallet, phrase) = try await Wallet.generateMnemonic(
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…")
)

// Generate + encrypt in one round-trip. The blob is the at-rest form; persist it via
// any KeyStore.
let (wallet, phrase, blob) = try await Wallet.generateEncrypted(
    passphrase: userPassphrase,
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…")
)
try await keyStore.save(blob, id: "primary")

// TextEnvelope (`cardano-cli`-style `.skey` files on disk).
let (wallet, paymentSkeyURL, stakeSkeyURL) = try await Wallet.generateTextEnvelope(
    writeTo: keyDirectory,
    network: .preprod,
    provider: .blockfrost(projectId: "preprod_…")
)
```

`watchOnly`, `multisig`, and `hardware` wallets do not get `generate` factories by
design — they wrap pre-existing key material (vkeys, key hashes, device-generated
`.hwsfile`s) and there is no fresh-keypair operation to perform locally.

`MnemonicWallet.generate` accepts a `wordCount:` of 12 / 15 / 18 / 21 / 24 (default 24).
`TextEnvelopeWallet` also exposes a `generateInMemory(...)` variant that hands back the
raw 32-byte signing key payloads instead of writing them to disk, for callers that
want to persist via a custom `KeyStore`.

## Five lines to send ADA

```swift
import SwiftCardanoWallet

let wallet = try await Wallet.mnemonic(
    phrase: phrase,
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
| `Wallet.encrypted(blob:passphrase:...)` | Recover a wallet from a persisted `EncryptedBlob`. PBKDF2-SHA512 → AES-256-GCM. Returns a `.mnemonic(_:)` case after decryption. |
| `TextEnvelopeWallet` | Existing `cardano-cli` `.skey` files. Full send + sign. |
| `WatchOnlyWallet` | Verification keys **or just an address**. `prepareSend` builds; `sign()` throws `watchOnly` — pair with offline signing. Stake addresses (`stake1…`) are also accepted for reward / delegation monitoring. |
| `MultisigWallet` | Native-script multisig (N-of-M, all, any). Coordinator collects partial witnesses from cosigners and assembles. |
| `HardwareWallet` | Ledger / Trezor via `cardano-hw-cli`. macOS + Linux only (iOS traps with `unsupportedOperation`). |

See the [Wallet Types article](Sources/SwiftCardanoWallet/SwiftCardanoWallet.docc/Articles/WalletTypes.md)
for construction examples and trade-offs.

## Operations cheat sheet

```swift
// --- Available on the `Wallet` enum directly ---

// Read
let balance  = try await wallet.balance()              // ADA + multi-asset + rewards
let address  = try await wallet.primaryAddress()       // receive (mnemonic) / script (multisig) / etc.
let utxos    = try await wallet.utxos()
let canSign  = wallet.canSign                          // false for .watchOnly

// Send
try await wallet.send(lovelace: 5_000_000, to: addr)
try await wallet.sendTo(handle: "$alice", lovelace: 5_000_000)

// --- Stake / mint / governance live on `MnemonicWallet` ---
// (Multisig / hardware have their own multi-step flows; drop down via the typed accessor.)

guard let m = wallet.mnemonicWallet else { return }

// Stake
try await m.registerStake()
try await m.delegate(toPool: poolId)
try await m.claimAllRewards()

// Mint — native script (one-shot NFT)
try await m.mintNFT(name: "MyNFT", metadata: cip25)         // CIP-25 v1 default
let v2 = metadata.encode(policyId: pid, assetName: "MyNFT", version: .v2)

// Mint — Plutus policy
try await m.mint(
    amount: 1,
    assetName: "MyToken",
    plutusPolicy: .plutusV2Script(PlutusV2Script(data: compiledScript))
    // `redeemer:` defaults to a Unit redeemer; `collateral:` auto-picked from UTxOs
)

// Governance
try await m.delegateVote(to: .alwaysAbstain)
try await m.vote(on: govActionId, vote: .yes)
```

For multi-action transactions, build with `prepareSend(...)` / `prepareMint(...)` / etc.
on the concrete actor and chain the resulting `PreparedTransaction`s manually.

## Connecting a dApp (CIP-30)

```swift
import SwiftCardanoCIPs

let provider = try await wallet.mnemonicWallet!.cip30Provider(
    info: WalletInfo(name: "MyWallet", icon: "data:image/png;base64,…"),
    policy: CIP30ApprovalPolicy(
        approveSignTx:   { tx, _, ctx in await ui.confirmSignTx(tx, origin: ctx?.origin) },
        approveSignData: { addr, payload, ctx in await ui.confirmSignData(addr, payload, origin: ctx?.origin) },
        approveSubmitTx: { _, ctx in await ui.confirmSubmit(origin: ctx?.origin) }
    )
)
```

The returned `KeyStoreCIP30Provider` is the upstream reference implementation from
`swift-cardano-cips`. Every `signTx` / `signData` / `submitTx` call invokes the matching
approval closure first — there's no "always allow" backdoor. `partialSign: false` is
real: the provider checks required-signer hashes against the wallet's keys and throws
`TxSignError.proofGeneration` when any are missing. `signData` uses raw byte payloads
(no UTF-8 transcoding), so signing arbitrary bytes is well-defined.

Use `CIP30ApprovalPolicy.denyAll` as a safe placeholder during development; never ship
`.allowAll` — it's only for test harnesses.

## Security defaults

- **Mnemonic encryption.** `EncryptedKeyManager` → PBKDF2-HMAC-SHA512 (210,000 iters by
  default; 100k floor enforced on decrypt to reject tampered blobs) → AES-256-GCM via
  CryptoKit. Passphrase is NFKC-normalized before key derivation so composed vs
  decomposed accented characters produce the same key across devices.
- **Blob format.** v2 (current) uses a CBOR-map plaintext so future fields can be added
  without ambiguity. v1 (`\n`-delimited) blobs still decrypt — re-saving migrates them
  to v2.
- **On-disk permissions.** `FileKeyStore` chmods newly-created vault directories to
  `0o700` and every saved blob to `0o600` regardless of process umask.
- **Heap residue.** PBKDF2-derived keys and decrypted plaintext are zeroed via
  `memset_s` after use (best-effort defense-in-depth; see `Data.zeroize()` for the
  caveats).
- **dApp consent.** CIP-30 surface is gated on a required `CIP30ApprovalPolicy` — see
  the section above.

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
the full `swift-cardano-txbuilder` shortcut surface, **Plutus V1/V2/V3 minting**, and
**CIP-25 v2** NFT metadata. **220 hermetic tests (227 with the SQLite trait) — all green.**

See [`.agents/PLAN.md`](.agents/PLAN.md) for the full build sequence, dependencies, and
known follow-ups (Ogmios chain-sync, mixed software/hardware signing, verified Plutus
script fixtures for end-to-end auto-estimate testing).

## Requirements

- Swift 6.3+
- macOS 15+ / iOS 18+ / Linux (Swift 6 toolchain)
- Hardware wallet support requires `cardano-hw-cli` installed locally (`scm install
  cardano-hw-cli` from `swift-cardano-multitool`, or the upstream Vacuumlabs binary)

## License

Apache 2.0 — see [LICENSE](LICENSE).
