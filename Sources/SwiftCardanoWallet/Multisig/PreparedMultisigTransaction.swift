import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// An unsigned multisig `Transaction` plus the policy that produced it.
///
/// Differs from ``PreparedTransaction`` in that it has no `keyManager` / `signingPaths`: the
/// signers are external parties holding their own keys. Use ``signLocal(with:)`` to produce a
/// ``PartialWitness`` for one cosigner, then ``combine(_:)`` to assemble the final signed
/// transaction once the policy's threshold is met.
public struct PreparedMultisigTransaction: Sendable {

    /// The unsigned transaction. Already carries the native script in its witness set; only
    /// `vkeyWitnesses` is empty.
    public let transaction: Transaction

    /// Policy this transaction spends from. Carried so ``combine(_:)`` can sanity-check the
    /// supplied partials against the script's signer set.
    public let policy: MultisigPolicy

    /// Chain context used for submission. Same one that prepared the transaction.
    public let chainContext: any ChainContext

    public init(
        transaction: Transaction,
        policy: MultisigPolicy,
        chainContext: any ChainContext
    ) {
        self.transaction = transaction
        self.policy = policy
        self.chainContext = chainContext
    }

    /// CBOR encoding of the (still-unsigned) transaction. Persistable to disk for distribution
    /// to cosigners.
    public func exportCBOR() throws -> Data {
        transaction.payload
    }

    /// 32-byte blake2b-256 hash of the transaction body. Cosigners sign this verbatim; the
    /// combiner uses it to detect mismatched partials.
    public var bodyHash: Data {
        get throws { try transaction.transactionBody.hash() }
    }

    /// Sign the body with one cosigner's signing key locally and produce a
    /// ``PartialWitness`` ready to ship back to the coordinator.
    public func signLocal(with key: SigningKeyType) throws -> PartialWitness {
        let hash = try bodyHash
        do {
            let signature = try key.sign(data: hash)
            let vkey = try key.toVerificationKeyType()
            let witness = VerificationKeyWitness(vkey: vkey, signature: signature)
            return PartialWitness(bodyHash: hash, witness: witness)
        } catch {
            throw WalletError.wrappingSigning(error)
        }
    }

    /// Assemble the final signed transaction from N cosigner partials.
    ///
    /// - Validates that every partial is labelled with **this** transaction's body hash and
    ///   that its Ed25519 signature verifies over that hash with its own vkey. A forged or
    ///   relabelled partial throws, so it can't displace a genuine signature or count toward
    ///   the threshold.
    /// - De-duplicates by signer key hash (a malicious cosigner can't pad the witness set
    ///   by submitting twice).
    /// - Verifies the final witness count meets the policy's required-signer minimum.
    public func combine(_ partials: [PartialWitness]) throws -> SignedTransaction {
        let expectedHash = try bodyHash

        // Reject anything signing the wrong body.
        for partial in partials where partial.bodyHash != expectedHash {
            throw WalletError.signingFailed(
                "PartialWitness body hash does not match the prepared transaction."
            )
        }

        // Reject any partial whose signature doesn't verify over this body.
        for partial in partials {
            let ok = (try? partial.witness.vkey.verify(
                signature: partial.witness.signature,
                data: expectedHash
            )) ?? false
            guard ok else {
                throw WalletError.signingFailed(
                    "PartialWitness signature does not verify over this transaction body."
                )
            }
        }

        // De-duplicate by vkey-hash. Two partials from the same signer count as one.
        var byKeyHash: [VerificationKeyHash: VerificationKeyWitness] = [:]
        for partial in partials {
            let hash: VerificationKeyHash
            do {
                hash = try Self.keyHash(of: partial.witness.vkey)
            } catch {
                throw WalletError.signingFailed("Failed to hash partial witness vkey: \(error)")
            }
            if byKeyHash[hash] == nil {
                byKeyHash[hash] = partial.witness
            }
        }

        // Optional: warn if a partial's signer isn't part of the policy. Cardano will simply
        // ignore it on-chain (the script doesn't reference it), but it's almost always a bug.
        let allowed = Set(policy.signerKeyHashes())
        for hash in byKeyHash.keys where !allowed.contains(hash) {
            throw WalletError.signingFailed(
                "PartialWitness from signer \(hash.payload.toHex) is not part of the multisig policy."
            )
        }

        let required = policy.requiredSignerCount()
        guard byKeyHash.count >= required else {
            throw WalletError.signingFailed(
                "Multisig requires \(required) cosigner(s); only \(byKeyHash.count) supplied."
            )
        }

        // Stable signer order (sorted by key hash) so two coordinators producing the same
        // partials produce byte-identical final txs. Helps with deterministic txIds.
        let sorted = byKeyHash
            .sorted { $0.key.payload.lexicographicallyPrecedes($1.key.payload) }
            .map(\.value)

        var witnessSet = transaction.transactionWitnessSet
        witnessSet.vkeyWitnesses = sorted.isEmpty ? nil : .nonEmptyOrderedSet(NonEmptyOrderedSet(sorted))

        let signed = Transaction(
            transactionBody: transaction.transactionBody,
            transactionWitnessSet: witnessSet,
            valid: transaction.valid,
            auxiliaryData: transaction.auxiliaryData
        )

        return SignedTransaction(transaction: signed, chainContext: chainContext)
    }

    /// `VerificationKeyType` doesn't expose `.hash()` directly because the extended variant
    /// returns a `(hash, trimmed-key)` tuple. Centralise the unwrap so callers don't have to
    /// switch on the enum.
    static func keyHash(of vkey: VerificationKeyType) throws -> VerificationKeyHash {
        switch vkey {
        case .verificationKey(let v):
            return try v.hash()
        case .extendedVerificationKey(let v):
            let result: (VerificationKeyHash, VerificationKey) = try v.hash()
            return result.0
        }
    }
}
