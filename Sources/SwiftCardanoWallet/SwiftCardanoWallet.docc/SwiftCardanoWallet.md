# ``SwiftCardanoWallet``

A high-level Swift wallet SDK for Cardano. Open a wallet, read balance, build / sign /
submit transactions — without dropping down to `TxBuilder` or `ChainContext` directly.

## Overview

`SwiftCardanoWallet` composes the [`swift-cardano-*`](https://github.com/Kingpin-Apps)
packages (`core`, `txbuilder`, `chain`, `txvalidator`, `cips`, `uplc`, `utils`,
`handles-api`) into a single ergonomic surface. Six wallet kinds — mnemonic,
TextEnvelope (`.skey` files), watch-only, encrypted, native-script multisig, hardware
(Ledger / Trezor) — share a small set of operations: send, stake, mint (native + Plutus),
vote.

```swift
import SwiftCardanoWallet

let wallet = try await Wallet.mnemonic(
    phrase: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet…")
)
let balance = try await wallet.balance()
let txId    = try await wallet.send(lovelace: 5_000_000, to: address)
```

The top-level ``Wallet`` enum unifies all five concrete wallet kinds
(``MnemonicWallet``, ``TextEnvelopeWallet``, ``WatchOnlyWallet``, ``MultisigWallet``,
``HardwareWallet``) behind one `Sendable` value. Common reads (``Wallet/kind``,
``Wallet/network``, ``Wallet/primaryAddress()``, ``Wallet/utxos()``,
``Wallet/balance()``, ``Wallet/canSign``) dispatch automatically; extract the concrete
actor via ``Wallet/mnemonicWallet`` / ``Wallet/textEnvelopeWallet`` /
``Wallet/watchOnlyWallet`` / ``Wallet/multisigWallet`` / ``Wallet/hardwareWallet`` for
operations the enum doesn't expose (stake / mint / governance live on the concrete actor).

Encryption is a key-management concern, not a runtime distinction — there is no
"encrypted" case. ``Wallet/encrypted(blob:passphrase:network:provider:accountIndex:utxoStore:gapLimit:handleResolver:)``
decrypts an ``EncryptedBlob`` and returns a ``Wallet/mnemonic(_:)`` case.

## Topics

### Getting started

- <doc:QuickStart>
- <doc:WalletTypes>
- <doc:CIP30Provider>

### Wallet types

- ``Wallet``
- ``WalletProtocol``
- ``MnemonicWallet``
- ``TextEnvelopeWallet``
- ``WatchOnlyWallet``
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
- ``SQLiteUTxOStore``
- ``HandleResolver``
- ``DefaultHandleResolver``

### Providers

- ``ProviderConfig``
- ``ProviderFactory``

### Models

- ``WalletBalance``
- ``CIP25NFTMetadata``
- ``CIP25Version``
- ``GovernanceAnchor``

### Errors

- ``WalletError``
- ``WalletKind``
