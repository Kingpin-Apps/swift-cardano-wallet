import Foundation
import SwiftCardanoCore

/// A native-script-based multisig policy. Wraps a `NativeScript` (typically a
/// ``SwiftCardanoCore/ScriptAll``, ``SwiftCardanoCore/ScriptAny`` or
/// ``SwiftCardanoCore/ScriptNofK`` of ``SwiftCardanoCore/ScriptPubkey`` leaves) and exposes the
/// derived script hash plus address helpers.
///
/// Multisig in Cardano is fundamentally a script-locked address: anyone holding the policy can
/// observe its UTxOs (read-only), and a transaction spending those UTxOs is valid only if the
/// witness set carries the script and enough cosigner vkey witnesses to satisfy the script.
///
/// This wrapper does **not** hold any signing keys. Cosigners sign with their own
/// ``SwiftCardanoCore/SigningKeyType`` (delivered through whatever ``KeyManager`` they use) and
/// hand the resulting ``PartialWitness`` back to whoever is assembling the final transaction.
public struct MultisigPolicy: Sendable, Equatable {

    /// The underlying native script. Persisted to / from CBOR via ``SwiftCardanoCore/NativeScript``.
    public let nativeScript: NativeScript

    /// Network the derived addresses should belong to.
    public let network: Network

    /// Construct directly from a fully-built ``SwiftCardanoCore/NativeScript``. Use the static
    /// helpers below for the common N-of-M / all / any cases.
    public init(nativeScript: NativeScript, network: Network) {
        self.nativeScript = nativeScript
        self.network = network
    }

    /// Hash the script with blake2b-224, prepended with the native-script tag byte. Cached on
    /// each call (the underlying CBOR encode is cheap, but callers can hoist if needed).
    public func scriptHash() throws -> ScriptHash {
        do {
            return try nativeScript.scriptHash()
        } catch {
            throw WalletError.configurationMissing("Failed to hash multisig script: \(error)")
        }
    }

    /// Base address: payment is the script, staking part is whatever the caller supplies
    /// (usually a stake-key hash from one of the cosigners, or a stake-script hash for fully
    /// script-controlled staking).
    public func paymentAddress(stakingPart: StakingPart? = nil) throws -> Address {
        let scriptHash = try scriptHash()
        return try Address(
            paymentPart: .scriptHash(scriptHash),
            stakingPart: stakingPart,
            network: network.networkId
        )
    }

    /// Enterprise address — payment-only (no staking part). Most practical for treasury /
    /// short-lived multisig vaults that don't care about staking rewards.
    public func enterpriseAddress() throws -> Address {
        try paymentAddress(stakingPart: nil)
    }

    /// Reward (stake) address whose stake credential is the script itself. Use when the
    /// multisig should also control delegation / rewards.
    public func rewardAddress() throws -> Address {
        let scriptHash = try scriptHash()
        return try Address(
            stakingPart: .scriptHash(scriptHash),
            network: network.networkId
        )
    }

    // MARK: - Convenience builders

    /// `M-of-N` threshold across the supplied verification-key hashes. Cardano allows any
    /// `M` between 1 and `N`; we surface the same constraint as a friendly precondition so
    /// callers don't end up with an unspendable script by accident.
    public static func nOfM(
        required: Int,
        signerKeyHashes: [VerificationKeyHash],
        network: Network
    ) throws -> MultisigPolicy {
        guard required >= 1, required <= signerKeyHashes.count else {
            throw WalletError.configurationMissing(
                "Multisig threshold \(required) must be between 1 and \(signerKeyHashes.count)."
            )
        }
        guard !signerKeyHashes.isEmpty else {
            throw WalletError.configurationMissing("Multisig requires at least one signer.")
        }
        let leaves = signerKeyHashes.map { hash in
            NativeScript.scriptPubkey(ScriptPubkey(keyHash: hash))
        }
        return MultisigPolicy(
            nativeScript: .scriptNofK(ScriptNofK(required: required, scripts: leaves)),
            network: network
        )
    }

    /// `ScriptAll` — every supplied key must sign.
    public static func all(
        signerKeyHashes: [VerificationKeyHash],
        network: Network
    ) throws -> MultisigPolicy {
        guard !signerKeyHashes.isEmpty else {
            throw WalletError.configurationMissing("Multisig requires at least one signer.")
        }
        let leaves = signerKeyHashes.map {
            NativeScript.scriptPubkey(ScriptPubkey(keyHash: $0))
        }
        return MultisigPolicy(
            nativeScript: .scriptAll(ScriptAll(scripts: leaves)),
            network: network
        )
    }

    /// `ScriptAny` — at least one supplied key must sign.
    public static func any(
        signerKeyHashes: [VerificationKeyHash],
        network: Network
    ) throws -> MultisigPolicy {
        guard !signerKeyHashes.isEmpty else {
            throw WalletError.configurationMissing("Multisig requires at least one signer.")
        }
        let leaves = signerKeyHashes.map {
            NativeScript.scriptPubkey(ScriptPubkey(keyHash: $0))
        }
        return MultisigPolicy(
            nativeScript: .scriptAny(ScriptAny(scripts: leaves)),
            network: network
        )
    }

    // MARK: - Introspection

    /// Flatten the script tree and return every `scriptPubkey` keyHash it references. Useful
    /// for tools that want to display "who can sign this" without parsing the native script
    /// themselves.
    public func signerKeyHashes() -> [VerificationKeyHash] {
        Self.collectKeyHashes(from: nativeScript)
    }

    private static func collectKeyHashes(from script: NativeScript) -> [VerificationKeyHash] {
        switch script {
        case .scriptPubkey(let leaf):
            return [leaf.keyHash]
        case .scriptAll(let all):
            return all.scripts.flatMap { collectKeyHashes(from: $0) }
        case .scriptAny(let any):
            return any.scripts.flatMap { collectKeyHashes(from: $0) }
        case .scriptNofK(let nofk):
            return nofk.scripts.flatMap { collectKeyHashes(from: $0) }
        case .invalidBefore, .invalidHereAfter:
            return []
        }
    }

    /// Heuristic: how many cosigners the policy *requires* before a transaction will validate
    /// on-chain. Used by `MultisigWallet.prepareSend(...)` to set a conservative
    /// `witnessOverride` for fee estimation.
    public func requiredSignerCount() -> Int {
        Self.requiredCount(for: nativeScript)
    }

    private static func requiredCount(for script: NativeScript) -> Int {
        switch script {
        case .scriptPubkey:
            return 1
        case .scriptAll(let all):
            return all.scripts.reduce(0) { $0 + requiredCount(for: $1) }
        case .scriptAny(let any):
            // Cheapest single subscript is enough; pick the min.
            return any.scripts.map { requiredCount(for: $0) }.min() ?? 0
        case .scriptNofK(let nofk):
            // Conservative: assume the M cheapest leaves are picked.
            let costs = nofk.scripts.map { requiredCount(for: $0) }.sorted()
            return costs.prefix(nofk.required).reduce(0, +)
        case .invalidBefore, .invalidHereAfter:
            return 0
        }
    }
}
