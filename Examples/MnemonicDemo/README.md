# MnemonicDemo

Minimal SwiftUI app demonstrating `swift-cardano-wallet`. Paste a BIP-39 mnemonic, pick a
network, and the app opens the wallet against [Koios](https://koios.rest) and shows your
receive address + lovelace balance. Read-only — no send / sign / submit buttons.

## Run

```sh
cd Examples/MnemonicDemo
swift run MnemonicDemo
```

A macOS window opens (requires macOS 15+ — same minimum as the parent package).

## What it shows

- `MnemonicWallet(mnemonic:network:provider:)` construction
- `receiveAddress()` derivation
- `balance()` over Koios

## What it deliberately omits

- **Persistence.** Mnemonic lives in memory only; nothing is written to disk or keychain.
  See [`KeychainKeyStore`](../../Sources/SwiftCardanoWallet/Storage/KeychainKeyStore.swift)
  + [`EncryptedKeyManager`](../../Sources/SwiftCardanoWallet/Keys/EncryptedKeyManager.swift)
  for the production pattern.
- **Send / sign / submit.** Those need real funds and would obscure the structure of the
  demo. See `prepareSend(lovelace:to:)` on `MnemonicWallet` for the entry point.
- **Hardware wallet.** See `HardwareWallet` (PR 13) for that flow — it requires
  `cardano-hw-cli` on the host and a connected Ledger / Trezor.

## Files

- `Sources/MnemonicDemo/MnemonicDemoApp.swift` — the whole app: `App`, `WalletViewModel`,
  `ContentView`. Single file; ~110 lines.
- `Package.swift` — depends on the parent package via local path.
