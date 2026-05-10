# Wallet types

`SwiftCardanoWallet` ships six wallet types. Pick the one that matches your key custody
story.

## Overview

The package separates _key management_ from _wallet operations_:

- ``KeyManager`` is a protocol describing how to materialise verification and signing
  keys for a given derivation path. Five conforming types ship in v0.1.0.
- ``MnemonicWallet`` is the canonical _wallet_ — an `actor` that owns one
  ``Account`` + one ``KeyManager`` + one chain context, and exposes
  send / stake / mint / governance shortcuts.
- ``MultisigWallet`` and ``HardwareWallet`` are sibling _wallet_ types that don't fit the
  single-`KeyManager` shape. Each has its own preparation + signing flow.

You'll typically use ``MnemonicWallet`` with the appropriate ``KeyManager`` injected
directly, or one of the sibling types.

## Mnemonic

```swift
let wallet = try await MnemonicWallet(
    mnemonic: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…"),
    passphrase: "",                 // optional BIP-39 passphrase
    accountIndex: 0,                // CIP-1852 account
    gapLimit: 20                    // BIP-44 standard
)
```

BIP-39 phrase + BIP-32 HD derivation per [CIP-1852](https://cips.cardano.org/cip/CIP-1852).
The default. Internally uses ``MnemonicKeyManager``.

## TextEnvelope (cardano-cli `.skey` files)

For workflows where keys live in `cardano-cli`-format files (`payment.skey`, `stake.skey`):

```swift
let km = try TextEnvelopeKeyManager(
    paymentSigningKeyPath: "/path/to/payment.skey",
    stakeSigningKeyPath: "/path/to/stake.skey"
)
// Pair with ChainContext through `MnemonicWallet`'s actor pattern, or drive TxBuilder directly.
```

Useful for migrating existing CLI-managed wallets, or for offline setups where keys are
generated outside the app.

## Watch-only

```swift
let km = WatchOnlyKeyManager(
    paymentVerificationKey: pVKey,
    stakeVerificationKey: sVKey
)
```

Public keys only. Every signing method throws ``WalletError/watchOnly``. Use cases:

- Read-only monitoring (balance, txs received).
- Building unsigned transactions on a "warm" machine for signing on a separate "cold"
  air-gapped device.
- Showing portfolio info in dashboards / accounting tools.

## Encrypted (passphrase-encrypted blob)

```swift
// Encrypt:
let km = try await EncryptedKeyManager(
    mnemonic: phrase,
    passphrase: userPassphrase
)
let blob = try await km.encryptedBlob(passphrase: userPassphrase)

// Persist via any KeyStore:
let store = KeychainKeyStore(service: "com.example.MyWallet")
try await store.save(blob, id: "primary")

// Decrypt later:
let restoredBlob = try await store.load(id: "primary")
let restored = try await EncryptedKeyManager(blob: restoredBlob, passphrase: userPassphrase)
```

PBKDF2-HMAC-SHA512 (210,000 iterations by default) → AES-256-GCM, via CryptoKit. Pair
with ``KeychainKeyStore`` (Apple) or ``FileKeyStore`` (cross-platform JSON-on-disk).

## Multisig (native script)

```swift
let policy = try MultisigPolicy.nOfM(
    required: 2,
    signerKeyHashes: [alice.keyHash, bob.keyHash, carol.keyHash],
    network: .mainnet
)
let wallet = try MultisigWallet(
    policy: policy,
    chainContext: someContext
)

let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)

// Each cosigner signs locally and ships back a PartialWitness:
let alicePartial = try prepared.signLocal(with: alicesSigningKey)
let bobPartial   = try prepared.signLocal(with: bobsSigningKey)

// Coordinator combines:
let signed = try prepared.combine([alicePartial, bobPartial])
let txid = try await signed.submit()
```

``MultisigWallet`` is a sibling type — it observes a script address and assembles
unsigned transactions, but it does not own any signing keys. Cosigners hold their own
keys and contribute ``PartialWitness`` values. ``MultisigPolicy`` supports
`nOfM`, `all`, and `any` builders over `ScriptPubkey` leaves; arbitrary `NativeScript`
trees (with time locks) can be passed via `MultisigPolicy(nativeScript:network:)`.

## Hardware (Ledger / Trezor)

```swift
let payment = HardwareKeyFile(
    hwsfilePath: "/path/to/payment.hwsfile",
    vkeyPath: "/path/to/payment.vkey",
    role: .payment
)
let stake = HardwareKeyFile(
    hwsfilePath: "/path/to/stake.hwsfile",
    vkeyPath: "/path/to/stake.vkey",
    role: .stake
)

let wallet = try await HardwareWallet(
    payment: payment,
    stake: stake,
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…"),
    hwcli: try await CardanoHWCLI(configuration: .init(cardano: .init()))
)

let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
let signed = try await prepared.signWithDevice()    // prompts the device
let txid = try await signed.submit()
```

Wraps `cardano-hw-cli` from `swift-cardano-utils` — the user must have the binary
installed locally. macOS / Linux only; iOS traps with
``WalletError/unsupportedOperation(_:)`` at construction (no shell-out support).

The `.hwsfile` + `.vkey` pairs are produced by the user once via
`cardano-hw-cli address key-gen` (offline). The wallet derives addresses from the `.vkey`
files in-process — no device interaction needed for read operations. Only signing requires
a connected device.

There's also a "manual" signing path for offline / air-gapped workflows:

```swift
try prepared.writeTxBody(to: "/tmp/tx.txbody")
// User runs `cardano-hw-cli transaction witness ...` externally.
let signed = try prepared.attachWitnesses(fromFiles: [
    "/tmp/payment.witness",
    "/tmp/stake.witness",
])
```

## Choosing

| Goal | Recommendation |
|---|---|
| New mainnet wallet, mobile or desktop app | ``MnemonicWallet`` + ``EncryptedKeyManager`` + ``KeychainKeyStore`` |
| Server with cold keys | ``MnemonicWallet`` + ``EncryptedKeyManager`` + ``FileKeyStore`` (in a secrets-managed dir) |
| Migrating a `cardano-cli` setup | ``TextEnvelopeKeyManager`` |
| Portfolio dashboard, no signing | ``WalletKind/watchOnly`` |
| Treasury / DAO / shared funds | ``MultisigWallet`` |
| Hardware-secured ada / NFT collection | ``HardwareWallet`` |
| Offline signing on air-gapped machine | ``WalletKind/watchOnly`` on warm side, ``MnemonicWallet`` or hardware on cold side |

Multiple wallet types can coexist in one app — each `actor` is independent.
