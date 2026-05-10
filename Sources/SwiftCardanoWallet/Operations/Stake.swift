import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

extension MnemonicWallet {

    // MARK: - Prepare (build, no signatures attached)

    /// Build (unsigned) a stake-address registration transaction for this wallet.
    ///
    /// Conway-era registration requires both payment (for the deposit) and stake (proving
    /// ownership of the credential being registered) witnesses.
    public func prepareStakeRegistration() async throws -> PreparedTransaction {
        let stakeVKey = try await keyManager.stakeVerificationKey(at: account.stakePath())
        let feeAddress = try await receiveAddress()

        let context = chainContextHandle()
        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2  // payment + stake

        let tx: Transaction
        do {
            tx = try await builder.transactions.stakeAddressRegistration(
                stakeVerificationKey: stakeVKey,
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

    /// Build (unsigned) a stake-delegation transaction targeting `poolId` (bech32 `pool1…`).
    public func prepareStakeDelegation(toPool poolId: String) async throws -> PreparedTransaction {
        let stakeVKey = try await keyManager.stakeVerificationKey(at: account.stakePath())
        let feeAddress = try await receiveAddress()
        let pool: PoolOperator
        do {
            pool = try PoolOperator(from: poolId)
        } catch {
            throw WalletError.configurationMissing("Invalid pool id '\(poolId)': \(error)")
        }

        let context = chainContextHandle()
        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2  // payment + stake

        let tx: Transaction
        do {
            tx = try await builder.transactions.stakeDelegation(
                stakeVerificationKey: stakeVKey,
                poolOperator: pool,
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

    /// Build (unsigned) a combined stake-registration + delegation transaction. Common first-time
    /// staker flow — saves a tx and a deposit roundtrip vs. two separate operations.
    public func prepareStakeRegistrationAndDelegation(toPool poolId: String) async throws -> PreparedTransaction {
        let stakeVKey = try await keyManager.stakeVerificationKey(at: account.stakePath())
        let feeAddress = try await receiveAddress()
        let pool: PoolOperator
        do {
            pool = try PoolOperator(from: poolId)
        } catch {
            throw WalletError.configurationMissing("Invalid pool id '\(poolId)': \(error)")
        }

        let context = chainContextHandle()
        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2

        let tx: Transaction
        do {
            tx = try await builder.transactions.stakeAddressRegistrationAndDelegation(
                stakeVerificationKey: stakeVKey,
                poolOperator: pool,
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

    /// Build (unsigned) a rewards-withdrawal transaction. The Cardano protocol requires
    /// withdrawing the full reward balance — there's no partial-withdraw mechanism. The funds
    /// can be sent to any address (multi-destination support is a future enhancement once
    /// upstream exposes it; for now, all rewards land at a single `to` address).
    ///
    /// - Parameter to: Destination address. Pass `nil` to credit the wallet's receive address.
    public func prepareStakeWithdrawal(to: Address? = nil) async throws -> PreparedTransaction {
        let stakeVKey = try await keyManager.stakeVerificationKey(at: account.stakePath())
        let feeAddress = try await receiveAddress()
        let destination = to ?? feeAddress

        let context = chainContextHandle()
        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2

        let tx: Transaction
        do {
            tx = try await builder.transactions.withdrawRewards(
                from: stakeVKey,
                to: destination,
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

    /// Build (unsigned) a stake-address deregistration transaction. Releases the registration
    /// deposit back to the wallet's fee-payment address.
    public func prepareStakeDeregistration() async throws -> PreparedTransaction {
        let stakeVKey = try await keyManager.stakeVerificationKey(at: account.stakePath())
        let feeAddress = try await receiveAddress()

        let context = chainContextHandle()
        let builder = TxBuilder(context: context)
        builder.witnessOverride = 2

        let tx: Transaction
        do {
            tx = try await builder.transactions.stakeAddressDeregistration(
                stakeVerificationKey: stakeVKey,
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

    // MARK: - One-shot (build → sign → submit)

    /// One-shot: register the stake address. Returns the submitted transaction id.
    @discardableResult
    public func registerStake() async throws -> String {
        try await prepareStakeRegistration().sign().submit()
    }

    /// One-shot: delegate the stake key to `poolId` (bech32 `pool1…`).
    @discardableResult
    public func delegate(toPool poolId: String) async throws -> String {
        try await prepareStakeDelegation(toPool: poolId).sign().submit()
    }

    /// One-shot: register-and-delegate in a single transaction.
    @discardableResult
    public func registerAndDelegate(toPool poolId: String) async throws -> String {
        try await prepareStakeRegistrationAndDelegation(toPool: poolId).sign().submit()
    }

    /// One-shot: withdraw the full reward balance.
    @discardableResult
    public func withdrawRewards(to: Address? = nil) async throws -> String {
        try await prepareStakeWithdrawal(to: to).sign().submit()
    }

    /// Withdraws all available rewards if the stake account has any. Returns the submitted
    /// transaction id, or `nil` if there were no rewards to claim.
    public func claimAllRewards() async throws -> String? {
        let context = chainContextHandle()
        let rewardAddr = try await rewardAddress()
        let info: [StakeAddressInfo]
        do {
            info = try await context.stakeAddressInfo(address: rewardAddr)
        } catch {
            throw WalletError.wrappingProvider(error)
        }
        guard let entry = info.first, entry.rewardAccountBalance > 0 else {
            return nil
        }
        return try await withdrawRewards()
    }

    /// One-shot: deregister the stake address (releasing the deposit).
    @discardableResult
    public func deregisterStake() async throws -> String {
        try await prepareStakeDeregistration().sign().submit()
    }
}
