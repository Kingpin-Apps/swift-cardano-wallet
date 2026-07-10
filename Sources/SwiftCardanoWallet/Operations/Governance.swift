import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

extension MnemonicWallet {

    /// Target for vote delegation. Mirrors CIP-1694's three options:
    /// delegate to a specific DRep, abstain by default, or signal no-confidence.
    public enum DRepTarget: Sendable, Equatable {
        case drepId(String)        // bech32 `drep1...` or `drep_script1...`
        case alwaysAbstain
        case alwaysNoConfidence
    }

    // MARK: - DRep registration / update / unregistration

    /// Register the wallet itself as a DRep. The DRep credential is the wallet's stake-key
    /// hash (CIP-1694 allows this; dedicated DRep keys are a future enhancement).
    public func prepareRegisterDRep(anchor: GovernanceAnchor? = nil) async throws -> PreparedTransaction {
        try await prepareDRepCertificate(kind: .register(anchor: anchor))
    }

    /// Update the metadata anchor for the wallet's DRep registration.
    public func prepareUpdateDRep(anchor: GovernanceAnchor? = nil) async throws -> PreparedTransaction {
        try await prepareDRepCertificate(kind: .update(anchor: anchor))
    }

    /// Unregister the wallet's DRep, releasing the deposit.
    public func prepareUnregisterDRep() async throws -> PreparedTransaction {
        try await prepareDRepCertificate(kind: .unregister)
    }

    // MARK: - Vote delegation

    /// Delegate the wallet's voting power to a DRep (or one of the always-abstain /
    /// always-no-confidence sentinels).
    public func prepareVoteDelegation(to target: DRepTarget) async throws -> PreparedTransaction {
        let stakeVKey = try await keyManager.stakeVerificationKey(at: account.stakePath())
        let drep = try Self.resolveDRep(target: target)
        let feeAddress = try await receiveAddress()

        let context = chainContextHandle()
        let utxos = try await self.utxos()

        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2  // payment + stake (governs the vote delegation)
        builder.potentialInputs = utxos

        let tx: Transaction
        do {
            tx = try await builder.transactions.voteDelegation(
                stakeVerificationKey: stakeVKey,
                drep: drep,
                feePaymentAddress: feeAddress,
                signingKeys: nil
            )
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        return PreparedTransaction(
            transaction: tx,
            signingPaths: [
                account.paymentPath(role: .external, index: 0),
                account.stakePath(),
            ],
            chainContext: context,
            keyManager: keyManager
        )
    }

    // MARK: - Casting a vote

    /// Cast a vote on a governance action **as a DRep**. Identifies the wallet's DRep
    /// credential from its stake-key hash.
    public func prepareVote(
        on govActionId: GovActionID,
        vote: Vote,
        anchor: GovernanceAnchor? = nil
    ) async throws -> PreparedTransaction {
        // Vote as this wallet's DRep — identified by its CIP-0105 DRep key hash.
        let drepVKey = try await keyManager.drepVerificationKey(at: account.drepPath())
        let drepKeyHash = try drepVKey.hash()
        let voter = Voter(credential: .drepKeyhash(drepKeyHash))

        let change = try await changeAddress()
        let context = chainContextHandle()
        let utxos = try await self.utxos()

        let resolvedAnchor: Anchor?
        if let anchor {
            resolvedAnchor = try anchor.toAnchor()
        } else {
            resolvedAnchor = nil
        }

        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2  // payment + stake (the DRep witness)
        builder.potentialInputs = utxos
        _ = builder.addVote(
            voter: voter,
            govActionId: govActionId,
            vote: vote,
            anchor: resolvedAnchor
        )

        let body: TransactionBody
        do {
            body = try await builder.build(changeAddress: change)
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let witnessSet: TransactionWitnessSet
        do {
            witnessSet = try builder.buildWitnessSet()
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let unsigned = Transaction(
            transactionBody: body,
            transactionWitnessSet: witnessSet,
            auxiliaryData: builder.auxiliaryData
        )

        return PreparedTransaction(
            transaction: unsigned,
            signingPaths: [
                account.paymentPath(role: .external, index: 0),
                account.drepPath(),
            ],
            chainContext: context,
            keyManager: keyManager
        )
    }

    // MARK: - One-shot helpers

    @discardableResult
    public func registerDRep(anchor: GovernanceAnchor? = nil) async throws -> String {
        try await prepareRegisterDRep(anchor: anchor).sign().submit()
    }

    @discardableResult
    public func updateDRep(anchor: GovernanceAnchor? = nil) async throws -> String {
        try await prepareUpdateDRep(anchor: anchor).sign().submit()
    }

    @discardableResult
    public func unregisterDRep() async throws -> String {
        try await prepareUnregisterDRep().sign().submit()
    }

    @discardableResult
    public func delegateVote(to target: DRepTarget) async throws -> String {
        try await prepareVoteDelegation(to: target).sign().submit()
    }

    @discardableResult
    public func vote(
        on govActionId: GovActionID,
        vote: Vote,
        anchor: GovernanceAnchor? = nil
    ) async throws -> String {
        try await prepareVote(on: govActionId, vote: vote, anchor: anchor).sign().submit()
    }

    // MARK: - Internals

    private enum DRepCertificateKind {
        case register(anchor: GovernanceAnchor?)
        case update(anchor: GovernanceAnchor?)
        case unregister
    }

    private func prepareDRepCertificate(kind: DRepCertificateKind) async throws -> PreparedTransaction {
        // CIP-0105: the DRep credential is a dedicated DRep key (role 3), not the stake key.
        let drepVKey = try await keyManager.drepVerificationKey(at: account.drepPath())
        let drepKeyHash = try drepVKey.hash()
        let drepCredential = DRepCredential(credential: .verificationKeyHash(drepKeyHash))
        let feeAddress = try await receiveAddress()

        let context = chainContextHandle()
        let utxos = try await self.utxos()

        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2  // payment + DRep key (the DRep credential)
        builder.potentialInputs = utxos

        // Resolve the anchor up-front so its specific error (e.g. configurationMissing) reaches
        // the caller verbatim instead of getting wrapped as validationFailed by the txbuilder catch.
        let resolvedAnchor: Anchor?
        switch kind {
        case .register(let a), .update(let a):
            resolvedAnchor = try a?.toAnchor()
        case .unregister:
            resolvedAnchor = nil
        }

        let tx: Transaction
        do {
            switch kind {
            case .register:
                tx = try await builder.transactions.registerDRep(
                    drepCredential: drepCredential,
                    anchor: resolvedAnchor,
                    feePaymentAddress: feeAddress,
                    signingKeys: nil
                )
            case .update:
                tx = try await builder.transactions.updateDRep(
                    drepCredential: drepCredential,
                    anchor: resolvedAnchor,
                    feePaymentAddress: feeAddress,
                    signingKeys: nil
                )
            case .unregister:
                tx = try await builder.transactions.unregisterDRep(
                    drepCredential: drepCredential,
                    feePaymentAddress: feeAddress,
                    signingKeys: nil
                )
            }
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        return PreparedTransaction(
            transaction: tx,
            signingPaths: [
                account.paymentPath(role: .external, index: 0),
                account.drepPath(),
            ],
            chainContext: context,
            keyManager: keyManager
        )
    }

    /// The wallet's own DRep id (bech32 `drep1…`), derived from its CIP-0105 DRep key. This is the
    /// credential others delegate their vote to, and the identity used when this wallet votes.
    public func drepID() async throws -> String {
        let drepVKey = try await keyManager.drepVerificationKey(at: account.drepPath())
        let drep = DRep(credential: .verificationKeyHash(try drepVKey.hash()))
        return try drep.toBech32()
    }

    private static func resolveDRep(target: DRepTarget) throws -> DRep {
        switch target {
        case .drepId(let bech32):
            do {
                return try DRep(from: bech32)
            } catch {
                throw WalletError.configurationMissing("Invalid DRep id '\(bech32)': \(error)")
            }
        case .alwaysAbstain:
            return DRep(credential: .alwaysAbstain)
        case .alwaysNoConfidence:
            return DRep(credential: .alwaysNoConfidence)
        }
    }
}
