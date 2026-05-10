import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// An unsigned `Transaction` plus the metadata the wallet needs to sign and submit it.
///
/// Produced by ``MnemonicWallet/prepareSend(lovelace:to:)`` and friends. Call
/// ``sign()`` to attach the wallet's signatures, or ``exportCBOR()`` to hand off
/// to a separate signer (offline, hardware, multisig).
public struct PreparedTransaction: Sendable {
    public let transaction: Transaction
    public let signingPaths: [DerivationPath]
    public let chainContext: any ChainContext
    public let keyManager: KeyManager

    public init(
        transaction: Transaction,
        signingPaths: [DerivationPath],
        chainContext: any ChainContext,
        keyManager: KeyManager
    ) {
        self.transaction = transaction
        self.signingPaths = signingPaths
        self.chainContext = chainContext
        self.keyManager = keyManager
    }

    /// CBOR encoding of the (still-unsigned) transaction. Persistable to disk for offline signing.
    public func exportCBOR() -> Data {
        transaction.payload
    }

    /// Sign the transaction with every key derived from ``signingPaths``.
    ///
    /// Dispatches by ``DerivationPath/role``: `.external` / `.change` paths go through the
    /// payment key; `.stake` paths go through the stake key. Other roles are reserved for
    /// later PRs (DRep / committee).
    public func sign() async throws -> SignedTransaction {
        // Keyed by vkey hash so two paths that resolve to the same key (which would emit
        // identical witnesses anyway) don't pollute the witness set with duplicates. The
        // node would reject duplicate witnesses, and any caller passing repeated paths is
        // almost certainly buggy — silently collapsing them is the safer recovery.
        var byKeyHash: [Data: VerificationKeyWitness] = [:]
        let bodyHash = transaction.transactionBody.hash()

        for path in signingPaths {
            let skeyType: SigningKeyType
            switch path.role {
            case .external, .change:
                skeyType = try await keyManager.paymentSigningKeyType(at: path)
            case .stake:
                skeyType = try await keyManager.stakeSigningKeyType(at: path)
            case .drep, .ccCold, .ccHot:
                throw WalletError.unsupportedOperation(
                    "Signing for role \(path.role) is not supported until PR 8 (governance keys)"
                )
            }
            do {
                let signature = try skeyType.sign(data: bodyHash)
                let vkeyType = try skeyType.toVerificationKeyType()
                let witness = VerificationKeyWitness(vkey: vkeyType, signature: signature)
                // Use the raw vkey payload as the dedup key — `Data` is hashable and two
                // signatures from the same key over the same body produce the same vkey
                // payload, so this is the cheapest stable identity.
                byKeyHash[vkeyType.payload] = witness
            } catch {
                throw WalletError.wrappingSigning(error)
            }
        }

        var witnessSet = transaction.transactionWitnessSet
        if !byKeyHash.isEmpty {
            // Stable order (lexicographic by vkey payload) so two callers producing the
            // same set of paths produce byte-identical signed txs / txIds.
            let witnesses = byKeyHash
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }
                .map(\.value)
            witnessSet.vkeyWitnesses = .nonEmptyOrderedSet(NonEmptyOrderedSet(witnesses))
        }

        let signed = Transaction(
            transactionBody: transaction.transactionBody,
            transactionWitnessSet: witnessSet,
            valid: transaction.valid,
            auxiliaryData: transaction.auxiliaryData
        )

        return SignedTransaction(
            transaction: signed,
            chainContext: chainContext
        )
    }
}
