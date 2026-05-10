# Quick start

Open a wallet, check balance, send ADA — the five-lines-of-code path.

## Overview

This article walks through the smallest useful program: open an HD wallet from a BIP-39
mnemonic, query its balance, and send 5 ADA to another address. We use Blockfrost as
the chain provider; `Koios` and `Ogmios` are drop-in replacements via ``ProviderConfig``.

## The five lines

```swift
import SwiftCardanoWallet

let wallet = try await MnemonicWallet(
    mnemonic: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…")
)
let txId = try await wallet.send(
    lovelace: 5_000_000,
    to: try Address.fromBech32("addr1q…")
)
print(txId)
```

That's it — `send(lovelace:to:)` builds the transaction, signs it with the wallet's keys,
and submits via the chosen provider. The returned `String` is the on-chain transaction id.

## Step by step

If you want to inspect the transaction before submitting (typical for production code that
should show the fee to the user first), break the call apart:

### 1. Construct the wallet

```swift
let wallet = try await MnemonicWallet(
    mnemonic: phrase,                                   // 12 / 15 / 18 / 21 / 24 word BIP-39
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…"),
    accountIndex: 0,                                    // CIP-1852 account index
    gapLimit: 20                                        // BIP-44 standard
)
```

The wallet is an `actor`. Construction is `async` because it resolves the provider — for
`Blockfrost`, that's an HTTP capability check. No keys touch disk; the mnemonic is held in
memory.

### 2. Read state

```swift
let receive = try await wallet.receiveAddress()         // role 0, index 0
let balance = try await wallet.balance()                // ADA + multi-asset + rewards
let utxos   = try await wallet.utxos()                  // tracker-cached snapshot
print("receive: \(try receive.toBech32())")
print("ada: \(balance.lovelace) (over \(balance.utxoCount) UTxOs)")
```

`balance()` triggers an initial chain sweep across the `external` and `change` roles up to
`gapLimit`. Subsequent calls return the cached snapshot until you explicitly call
`refresh()` (e.g. after a successful submit).

### 3. Build the transaction

```swift
let dest = try Address.fromBech32("addr1q…")
let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)

print("fee: \(prepared.transaction.transactionBody.fee) lovelace")
print("signing paths: \(prepared.signingPaths.count)")
```

``PreparedTransaction`` holds the unsigned `Transaction`, the derivation paths required
to sign each input, the underlying chain context, and a reference to the wallet's
``KeyManager``. Coin selection has already run; the fee is final.

### 4. Sign

```swift
let signed = try await prepared.sign()
```

``PreparedTransaction/sign()`` walks each derivation path, asks the wallet's
``KeyManager`` for the matching signing key, signs the body hash, and assembles the vkey
witnesses. The result is a fully witnessed ``SignedTransaction``.

### 5. Submit

```swift
let txId = try await signed.submit()
print(txId)
```

`submit()` hands the CBOR-encoded transaction to the provider and returns the transaction
id reported by the backend.

If you want a fire-and-forget version, the original five-line snippet is just:

```swift
let txId = try await wallet.send(lovelace: 5_000_000, to: dest)
```

## Networks

| Network | Provider examples |
|---|---|
| `.mainnet` | `.blockfrost(projectId: "mainnet…")`, `.koios(network: .mainnet)` |
| `.preprod` | `.blockfrost(projectId: "preprod…")`, `.koios(network: .preprod)` |
| `.preview` | `.blockfrost(projectId: "preview…")`, `.koios(network: .preview)` |

For unit tests against a stub backend, use `provider: .custom(make: { ... })` and supply
your own ``SwiftCardanoChain/ChainContext`` implementation — see
`Tests/SwiftCardanoWalletTests/StubChainContext.swift` for the pattern.

## What's next

- <doc:WalletTypes> — CLI keys, encrypted blobs, watch-only, multisig, hardware.
- ``MnemonicWallet/sendTo(handle:lovelace:)`` — resolve `$alice` → address via
  `swift-handles-api`, then send. Pass a ``DefaultHandleResolver`` to the wallet's
  `handleResolver:` init parameter.
- ``MnemonicWallet/registerStake()`` / ``MnemonicWallet/delegate(toPool:)`` /
  ``MnemonicWallet/claimAllRewards()`` — staking shortcuts.
- ``MnemonicWallet/mintNFT(metadata:policy:assetName:)`` — CIP-25 v1 NFT minting via
  native script.
- ``MnemonicWallet/delegateVote(to:)`` / ``MnemonicWallet/vote(on:vote:anchor:)`` —
  Conway-era governance.

## Persistence

The five-line snippet keeps the mnemonic in memory only. For a real app, you'll want to
encrypt the mnemonic with a user passphrase and persist the resulting blob. Use
``EncryptedKeyManager`` to encrypt and a ``KeyStore`` (``FileKeyStore`` for general use,
``KeychainKeyStore`` on Apple platforms) to store:

```swift
let encrypted = try await EncryptedKeyManager(
    mnemonic: phrase,
    passphrase: userPassphrase
)
let blob = try await encrypted.encryptedBlob(passphrase: userPassphrase)

let store = KeychainKeyStore(service: "com.example.MyWallet")
try await store.save(blob, id: "primary")
```

To re-open later:

```swift
let blob = try await store.load(id: "primary")
let km   = try await EncryptedKeyManager(blob: blob, passphrase: userPassphrase)
// `km` is a KeyManager — pair it with a chain context and you're back in business.
```
