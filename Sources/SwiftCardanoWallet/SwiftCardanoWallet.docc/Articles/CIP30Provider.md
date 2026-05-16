# Exposing a wallet to dApps (CIP-30)

Build a CIP-30 provider from a mnemonic wallet, gate every signing operation on
explicit user consent, and bridge it to a dApp.

## Overview

[CIP-30](https://cips.cardano.org/cip/CIP-30) is the JS-injection bridge between web
dApps and Cardano wallets. The dApp expects a `CIP30Provider` it can call to read
addresses, query UTxOs, request signatures, and submit transactions. `SwiftCardanoWallet`
delegates the spec details to ``SwiftCardanoCIPs/KeyStoreCIP30Provider`` (the upstream
reference implementation) and exposes a single builder on ``MnemonicWallet`` that wires
it up:

```swift
import SwiftCardanoCIPs

let provider = try await wallet.mnemonicWallet!.cip30Provider(
    info: WalletInfo(name: "MyWallet", icon: "data:image/png;base64,…"),
    policy: approvalPolicy
)
```

The returned ``SwiftCardanoCIPs/KeyStoreCIP30Provider`` is what the dApp calls. It owns:

- The wallet's role-0 / index-0 payment + stake keys (single-address surface; HD address
  discovery is deliberately not exposed via CIP-30).
- A ``SwiftCardanoCIPs/CIP30DataSource`` for UTxO lookups + tx submission. Defaults to an
  in-process adapter over the wallet's ``SwiftCardanoChain/ChainContext``.
- A ``SwiftCardanoCIPs/CIP30ApprovalPolicy`` — **required**, no default.

## Approval policy

Every sensitive call (`signTx`, `signData`, `submitTx`) invokes the matching closure on
the policy before doing any signing or network I/O. Returning `false` causes the provider
to throw the appropriate "user declined" error from the CIP-30 spec
(``SwiftCardanoCIPs/TxSignError/userDeclined(_:)``, etc.).

```swift
let policy = CIP30ApprovalPolicy(
    approveSignTx: { tx, partialSign, context in
        await myUI.confirmSignTransaction(
            tx,
            partialSign: partialSign,
            origin: context?.origin
        )
    },
    approveSignData: { address, payload, context in
        await myUI.confirmSignData(
            address: address,
            payloadBytes: payload,
            origin: context?.origin
        )
    },
    approveSubmitTx: { _, context in
        await myUI.confirmSubmit(origin: context?.origin)
    }
)
```

Two built-ins ship for non-production use:

- ``SwiftCardanoCIPs/CIP30ApprovalPolicy/denyAll`` — refuses every sensitive call. The
  safe default for development / unconfigured deployments. A misconfigured wallet wired
  with `.denyAll` literally cannot sign anything.
- ``SwiftCardanoCIPs/CIP30ApprovalPolicy/allowAll`` — approves every sensitive call.
  **For test harnesses only.** Shipping this in a wallet that talks to live dApps lets
  any site drain funds. The name is deliberately scary.

## Origin awareness

The `context: CIP30RequestContext?` parameter carries the dApp's origin and frame info
when the provider is driven through ``SwiftCardanoCIPs/CIP30WebBridge``. Use it to show
the user which site is asking:

```swift
approveSignTx: { tx, _, context in
    let origin = context?.origin ?? "<unknown>"
    return await myUI.confirmSignTransaction(tx, origin: origin)
}
```

For native callers that don't go through the bridge, `context` is `nil` — fall back to
whatever identifier is meaningful in that path.

## `partialSign` semantics

CIP-30's `signTx(_:partialSign:)` flag controls whether the wallet must produce signatures
for *every* required signer or may stop at the ones it owns:

- `partialSign: false` (default) — the wallet must cover every signer the body requires.
  The provider walks `requiredSigners`, certificate stake credentials, and withdrawal
  reward credentials, checks them against its own keys, and throws
  ``SwiftCardanoCIPs/TxSignError/proofGeneration(_:)`` if any are missing. The dApp
  is expected to handle that error explicitly.
- `partialSign: true` — the wallet contributes whatever signatures it can; the dApp is
  responsible for gathering the rest (e.g. multi-wallet flows, hardware co-signing).

This package's previous CIP-30 implementation treated `partialSign: false` as a no-op
and signed defensively in both cases. The upstream `KeyStoreCIP30Provider` enforces the
spec.

## `signData` and payloads

``SwiftCardanoCIPs/CIP30Provider/signData(address:payload:)`` signs raw bytes via
[CIP-8](https://cips.cardano.org/cip/CIP-8). The payload is signed verbatim — no UTF-8
transcoding, no hex fallback. A dApp passing arbitrary bytes gets exactly those bytes
signed, which is the well-defined contract.

The provider picks the signing key by matching the supplied `address`:

- Payment-credential address → wallet's payment key.
- Stake address (`stake1u…`) → wallet's stake key (if configured).
- Script-credential address → throws ``SwiftCardanoCIPs/DataSignError/addressNotPK(_:)``.
- Address whose credential doesn't match this wallet → throws
  ``SwiftCardanoCIPs/DataSignError/proofGeneration(_:)``.

## What's exposed vs. hidden

By design the provider is **single-address**. Other addresses the wallet's
``BalanceTracker`` may know about (gap-limit sweep across `external` / `change` roles)
are not visible to the dApp:

- ``SwiftCardanoCIPs/CIP30Provider/getChangeAddress()`` returns the role-0 / index-0
  receive address.
- ``SwiftCardanoCIPs/CIP30Provider/getUsedAddresses(paginate:)`` reports that single
  address if it has any UTxOs.
- ``SwiftCardanoCIPs/CIP30Provider/getUnusedAddresses()`` reports the single address if
  it has no UTxOs.

This is intentional: CIP-30 is the *external* surface presented to untrusted dApps, not
the wallet's internal HD view. Multi-address support would let a dApp enumerate (and
build transactions against) addresses the user never explicitly approved.

## Bridging to a `WKWebView`

The upstream package ships ``SwiftCardanoCIPs/CIP30WebBridge`` and
``SwiftCardanoCIPs/KeyStoreCIP30Initial`` for wiring this into a `WKWebView`. See
``SwiftCardanoCIPs/KeyStoreCIP30Initial`` for the per-origin enable / consent flow that
sits between the dApp's `cardano.{walletName}.enable()` call and the provider this article
shows how to build.

## What's next

- ``SwiftCardanoCIPs/CIP30ApprovalPolicy`` — full API for the consent gate.
- ``SwiftCardanoCIPs/KeyStoreCIP30Provider`` — provider type returned by the builder.
- ``SwiftCardanoCIPs/CIP30RequestContext`` — origin / frame info passed to approval
  closures.
- ``MnemonicWallet/cip30Provider(info:policy:dataSource:grantedExtensions:)`` — the
  builder this article documents.
