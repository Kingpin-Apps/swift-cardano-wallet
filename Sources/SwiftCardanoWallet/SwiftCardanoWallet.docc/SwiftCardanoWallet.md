# ``SwiftCardanoWallet``

A high-level Swift wallet SDK for Cardano. Open a wallet, read balance, build / sign /
submit transactions — without dropping down to `TxBuilder` or `ChainContext` directly.

## Overview

`SwiftCardanoWallet` composes the [`swift-cardano-*`](https://github.com/Kingpin-Apps)
packages (`core`, `txbuilder`, `chain`, `txvalidator`, `cips`, `utils`, `handles-api`)
into a single ergonomic surface. Six wallet types — mnemonic, TextEnvelope, watch-only,
encrypted, multisig, hardware — share a small set of operations: send, stake, mint, vote.

```swift
import SwiftCardanoWallet

let wallet = try await MnemonicWallet(
    mnemonic: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet…")
)
let balance = try await wallet.balance()
let txId    = try await wallet.send(lovelace: 5_000_000, to: address)
```

## Topics

### Getting started

- <doc:QuickStart>
- <doc:WalletTypes>

### Wallet types

- ``MnemonicWallet``
- ``MultisigWallet``
- ``HardwareWallet``

### Key managers

- ``KeyManager``
- ``MnemonicKeyManager``
- ``TextEnvelopeKeyManager``
- ``WatchOnlyKeyManager``
- ``EncryptedKeyManager``

### Account & derivation

- ``Account``
- ``DerivationPath``

### Transaction lifecycle

- ``PreparedTransaction``
- ``SignedTransaction``
- ``PreparedMultisigTransaction``
- ``PreparedHardwareTransaction``
- ``PartialWitness``

### Multisig

- ``MultisigPolicy``
- ``MultisigWallet``
- ``PartialWitness``
- ``PreparedMultisigTransaction``

### Hardware wallets

- ``HardwareKeyFile``
- ``HardwareWallet``
- ``PreparedHardwareTransaction``

### Storage

- ``KeyStore``
- ``FileKeyStore``
- ``KeychainKeyStore``
- ``EncryptedBlob``

### Sync

- ``BalanceTracker``
- ``UTxOStore``
- ``InMemoryUTxOStore``
- ``HandleResolver``
- ``DefaultHandleResolver``

### Providers

- ``ProviderConfig``
- ``ProviderFactory``

### Models

- ``WalletBalance``
- ``CIP25NFTMetadata``
- ``GovernanceAnchor``

### Errors

- ``WalletError``
- ``WalletKind``
