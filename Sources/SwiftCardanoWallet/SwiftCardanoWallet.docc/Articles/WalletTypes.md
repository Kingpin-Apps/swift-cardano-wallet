# Wallet types

`SwiftCardanoWallet` ships five wallet runtime types unified behind the ``Wallet`` enum,
plus a sixth "encrypted" entry point that decrypts an ``EncryptedBlob`` and returns a
``Wallet/mnemonic(_:)`` case. Pick the factory that matches your key custody story.

## Overview

The package separates _key management_ (``KeyManager`` and its conformers) from _wallet
runtimes_ (actor types that own a chain context + signing flow):

- ``Wallet`` is the canonical entry-point — a `Sendable` enum with five cases that
  wraps the concrete actors. Common reads dispatch through the enum; signing / stake /
  mint / governance flows live on the concrete actor and are reachable via typed
  accessors like ``Wallet/mnemonicWallet``.
- ``WalletProtocol`` is the common shape for HD-style wallets backed by a single
  ``KeyManager``. ``MnemonicWallet``, ``TextEnvelopeWallet``, and ``WatchOnlyWallet``
  conform. ``MultisigWallet`` and ``HardwareWallet`` are sibling types that don't fit
  the single-`KeyManager` shape and have their own preparation + signing flows.

The factory table:

| Factory | Returns | When to use |
|---|---|---|
| ``Wallet/mnemonic(phrase:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)`` | ``Wallet/mnemonic(_:)`` | BIP-39 phrase. The default. |
| ``Wallet/encrypted(blob:passphrase:network:provider:accountIndex:utxoStore:gapLimit:handleResolver:)`` | ``Wallet/mnemonic(_:)`` (after decrypt) | Persisted ``EncryptedBlob``. |
| ``Wallet/textEnvelope(paymentKeyFile:stakeKeyFile:network:provider:accountIndex:)`` | ``Wallet/textEnvelope(_:)`` | Existing `cardano-cli` `.skey` files. |
| ``Wallet/watchOnly(paymentVerificationKey:stakeVerificationKey:network:provider:accountIndex:)`` | ``Wallet/watchOnly(_:)`` | Public keys you've parsed in-memory. |
| ``Wallet/watchOnly(paymentVKeyFile:stakeVKeyFile:network:provider:accountIndex:)`` | ``Wallet/watchOnly(_:)`` | `.vkey` files on disk. |
| ``Wallet/watchOnly(address:network:provider:accountIndex:)`` | ``Wallet/watchOnly(_:)`` | Just a bech32 address — no keys at all. |
| ``Wallet/multisig(policy:provider:stakingPart:)`` | ``Wallet/multisig(_:)`` | Native-script multisig vault. |
| ``Wallet/hardware(payment:stake:network:provider:hwcli:)`` | ``Wallet/hardware(_:)`` | Ledger / Trezor via `cardano-hw-cli`. |

## Mnemonic

```swift
let wallet = try await Wallet.mnemonic(
    phrase: "abandon abandon abandon … about",
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…"),
    passphrase: "",                 // optional BIP-39 passphrase
    accountIndex: 0,                // CIP-1852 account
    gapLimit: 20                    // BIP-44 standard
)
```

BIP-39 phrase + BIP-32 HD derivation per [CIP-1852](https://cips.cardano.org/cip/CIP-1852).
The default — backed by ``MnemonicKeyManager``. Address derivation walks the `external`
and `change` roles up to `gapLimit` (default 20).

To mint a **fresh** mnemonic wallet from scratch:

```swift
let (wallet, phrase) = try await Wallet.generateMnemonic(
    wordCount: 24,                  // 12 / 15 / 18 / 21 / 24 (default 24)
    language: .english,             // default; non-English currently throws — see note
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…")
)
// Display or persist `phrase` before the tuple goes out of scope — once it's gone,
// the keys are unrecoverable.
```

> Non-English BIP-39 wordlists are accepted in the signature but throw
> `WalletError.unsupportedOperation` at runtime: upstream
> ``SwiftCardanoCore/HDWallet/fromMnemonic(mnemonic:passphrase:)`` validates the
> supplied phrase against the English wordlist unconditionally, and Japanese phrases
> use a different separator (`\u{3000}`) per BIP-39. The parameter exists so the
> eventual fix is non-breaking.

## Encrypted (passphrase-encrypted blob)

```swift
// Encrypt + persist
let km = try await EncryptedKeyManager(mnemonic: phrase, passphrase: userPassphrase)
let blob = try await km.encryptedBlob(passphrase: userPassphrase)
let store = KeychainKeyStore(service: "com.example.MyWallet")
try await store.save(blob, id: "primary")

// Later: decrypt + open in one call
let restoredBlob = try await store.load(id: "primary")
let wallet = try await Wallet.encrypted(
    blob: restoredBlob,
    passphrase: userPassphrase,
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…")
)
// wallet.kind == .mnemonic — encryption is a key-management concern, not a runtime one.
```

PBKDF2-HMAC-SHA512 (210,000 iterations by default) → AES-256-GCM, via CryptoKit. Pair
with ``KeychainKeyStore`` (Apple) or ``FileKeyStore`` (cross-platform JSON-on-disk).

**Security details:**

- The passphrase is **NFKC-normalized** before key derivation, so a passphrase typed
  with composed `é` (one code point) decrypts a blob encrypted with the decomposed form
  (`e` + combining acute, two code points). Matches BIP-39's own normalization rule.
- ``EncryptedBlob`` is currently at **version 2** — plaintext is a CBOR map, robust to
  passphrases containing newlines and to future field additions. **Version 1**
  (`\n`-delimited plaintext) is still decryptable; re-saving migrates the blob in place.
- ``EncryptedKeyManager`` rejects blobs with `iterations < 100,000` on decrypt, even if
  the cipher would happily authenticate — defends against a tampered blob whose
  iteration count was rewritten to something trivially crackable.
- Derived keys and decrypted plaintext are wiped via `memset_s` after use as
  defense-in-depth (see `Data.zeroize()` for the caveats — ARC copies elsewhere in
  the process aren't reached).
- ``FileKeyStore`` chmods newly-created vault directories to `0o700` and every saved
  blob to `0o600` regardless of process umask. Existing directories supplied to
  ``FileKeyStore/init(directory:createIfMissing:)`` are left untouched.

For a one-shot **generate-and-encrypt** flow:

```swift
let (wallet, phrase, blob) = try await Wallet.generateEncrypted(
    passphrase: userPassphrase,
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…")
)
try await store.save(blob, id: "primary")
// Show `phrase` once for offline backup, then drop it from memory.
```

## TextEnvelope (`cardano-cli` `.skey` files)

```swift
let wallet = try await Wallet.textEnvelope(
    paymentKeyFile: URL(fileURLWithPath: "/path/to/payment.skey"),
    stakeKeyFile: URL(fileURLWithPath: "/path/to/stake.skey"),
    network: .mainnet,
    provider: .koios(network: .mainnet)
)
```

For workflows where keys live in `cardano-cli`-format files. Backed by
``TextEnvelopeWallet`` + ``TextEnvelopeKeyManager``. Single-address (CLI keys are flat,
not HD); full send + sign capability. Useful for migrating existing CLI-managed wallets
or for offline setups where keys are generated outside the app.

To mint fresh `.skey` files (matches the `cardano-cli address key-gen` filename
convention):

```swift
let (wallet, paymentSkeyURL, stakeSkeyURL) = try await Wallet.generateTextEnvelope(
    writeTo: keyDirectory,
    network: .preprod,
    provider: .blockfrost(projectId: "preprod_…")
)
```

If you'd rather keep the keys out of the filesystem entirely, use
``TextEnvelopeWallet/generateInMemory(network:provider:accountIndex:)`` — it returns the
wallet plus the raw 32-byte signing-key payloads for the caller to persist via a custom
``KeyStore``.

## Watch-only

Three construction paths, depending on what you have:

```swift
// 1. From parsed verification keys (most common in-app path)
let wallet = try await Wallet.watchOnly(
    paymentVerificationKey: pVKey,
    stakeVerificationKey: sVKey,
    network: .mainnet,
    provider: .koios()
)

// 2. From .vkey files on disk
let wallet = try await Wallet.watchOnly(
    paymentVKeyFile: URL(fileURLWithPath: "/path/to/payment.vkey"),
    stakeVKeyFile: URL(fileURLWithPath: "/path/to/stake.vkey"),
    network: .mainnet,
    provider: .koios()
)

// 3. From just an address — no keys at all
let wallet = try await Wallet.watchOnly(
    address: try Address.fromBech32("addr1q…"),  // or "stake1u…" for reward-only
    network: .mainnet,
    provider: .koios()
)
```

Read-only by design. ``Wallet/send(lovelace:to:)`` throws ``WalletError/watchOnly``;
``Wallet/sendTo(handle:lovelace:)`` does the same. But ``WatchOnlyWallet/prepareSend(lovelace:to:)``
on the concrete actor still builds an **unsigned** transaction — useful for the warm
side of an offline-signing workflow:

```swift
let prepared = try await wallet.watchOnlyWallet!.prepareSend(lovelace: 5_000_000, to: dest)
let cbor = prepared.exportCBOR()
// ship `cbor` to the cold machine that owns the signing keys
```

**Address-only construction** accepts three address shapes:

- **Base** (`addr1q…` with vkey-hash stake) — observes UTxOs + derives a reward
  address from the staking part.
- **Enterprise** (`addr1v…`, no stake part) or base-with-script-stake — observes UTxOs;
  ``WatchOnlyWallet/rewardAddress()`` throws.
- **Reward** (`stake1u…`) — reward-only mode. ``Wallet/utxos()`` returns `[]`
  (stake addresses don't hold UTxOs); ``WatchOnlyWallet/rewardAddress()`` returns the
  supplied address. Use ``Wallet/chainContext()`` + `stakeAddressInfo(...)` for
  rewards / delegation reads.

## Multisig (native script)

```swift
let policy = try MultisigPolicy.nOfM(
    required: 2,
    signerKeyHashes: [alice.keyHash, bob.keyHash, carol.keyHash],
    network: .mainnet
)
let wallet = try await Wallet.multisig(
    policy: policy,
    provider: .blockfrost(projectId: "mainnet_…")
)

// Build via the concrete actor — multisig flows aren't on the enum.
let prepared = try await wallet.multisigWallet!.prepareSend(
    lovelace: 5_000_000,
    to: dest
)

// Each cosigner signs locally and ships back a PartialWitness:
let alicePartial = try prepared.signLocal(with: alicesSigningKey)
let bobPartial   = try prepared.signLocal(with: bobsSigningKey)

// Coordinator combines:
let signed = try prepared.combine([alicePartial, bobPartial])
let txid = try await signed.submit()
```

``MultisigWallet`` is a sibling type — it observes a script address and assembles
unsigned transactions but does not own any signing keys. Cosigners hold their own
keys and contribute ``PartialWitness`` values. ``MultisigPolicy`` supports `.nOfM`,
`.all`, `.any` builders over `ScriptPubkey` leaves; arbitrary `NativeScript` trees
(with time locks) can be passed via `MultisigPolicy(nativeScript:network:)`.

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

let wallet = try await Wallet.hardware(
    payment: payment,
    stake: stake,
    network: .mainnet,
    provider: .blockfrost(projectId: "mainnet_…"),
    hwcli: try await CardanoHWCLI(configuration: .init(cardano: .init()))
)

let prepared = try await wallet.hardwareWallet!.prepareSend(lovelace: 5_000_000, to: dest)
let signed = try await prepared.signWithDevice()    // prompts the device
let txid = try await signed.submit()
```

Wraps `cardano-hw-cli` from `swift-cardano-utils`. The user must have the binary
installed locally. macOS / Linux only; iOS traps with
``WalletError/unsupportedOperation(_:)`` at construction (no shell-out support).

The `.hwsfile` + `.vkey` pairs are produced once via `cardano-hw-cli address key-gen`
(offline). The wallet derives addresses from the `.vkey` files in-process — no device
interaction needed for read operations. Only signing requires a connected device.

Manual signing path (offline / air-gapped):

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
| New mainnet wallet, mobile or desktop app | ``Wallet/mnemonic(phrase:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)`` + ``EncryptedKeyManager`` + ``KeychainKeyStore`` |
| Re-opening a persisted wallet from a passphrase | ``Wallet/encrypted(blob:passphrase:network:provider:accountIndex:utxoStore:gapLimit:handleResolver:)`` |
| Server with cold keys | ``Wallet/mnemonic(phrase:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)`` + ``EncryptedKeyManager`` + ``FileKeyStore`` (in a secrets-managed dir) |
| Migrating a `cardano-cli` setup | ``Wallet/textEnvelope(paymentKeyFile:stakeKeyFile:network:provider:accountIndex:)`` |
| Portfolio dashboard, no signing | ``Wallet/watchOnly(address:network:provider:accountIndex:)`` |
| Block-explorer-style monitoring (just a bech32) | ``Wallet/watchOnly(address:network:provider:accountIndex:)`` |
| Treasury / DAO / shared funds | ``Wallet/multisig(policy:provider:stakingPart:)`` |
| Hardware-secured ada / NFT collection | ``Wallet/hardware(payment:stake:network:provider:hwcli:)`` |
| Offline signing on air-gapped machine | ``Wallet/watchOnly(address:network:provider:accountIndex:)`` on warm side, ``Wallet/mnemonic(phrase:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)`` or hardware on cold side |

Multiple wallets can coexist in one app — each is an independent actor.
