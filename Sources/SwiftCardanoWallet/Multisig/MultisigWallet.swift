import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

/// Coordinator-side view of a native-script multisig vault.
///
/// Unlike ``MnemonicWallet``, a `MultisigWallet` does not own any signing keys — it merely
/// observes the script address on-chain and assembles unsigned transactions. Cosigners hold
/// their own keys and contribute ``PartialWitness`` values; the coordinator combines them via
/// ``PreparedMultisigTransaction/combine(_:)``.
///
/// The wallet is intentionally lightweight: no `BalanceTracker`, no gap-limit sweep. A
/// multisig vault is a single address (the script address), so we query the chain context
/// directly. If you want polled / cached UTxOs for a multisig vault, wrap the chain context
/// in your own subscription layer or shell-script around `refresh()`.
public actor MultisigWallet {

    /// Policy controlling who can spend.
    public nonisolated let policy: MultisigPolicy
    public nonisolated let kind: WalletKind = .multisig

    private nonisolated let chainContext: any ChainContext
    private nonisolated let _address: Address

    /// Construct from a policy and a provider config. Resolves the chain context eagerly so
    /// later `utxos()` / `prepareSend(...)` calls don't re-await provider setup.
    public init(
        policy: MultisigPolicy,
        provider: ProviderConfig,
        stakingPart: StakingPart? = nil
    ) async throws {
        if case .custom = provider {
            // skip the network sanity check for custom providers
        } else if provider.network != policy.network {
            throw WalletError.configurationMissing(
                "Provider network \(provider.network) does not match multisig policy network \(policy.network)."
            )
        }

        self.policy = policy
        self.chainContext = try await ProviderFactory.make(provider)
        self._address = try policy.paymentAddress(stakingPart: stakingPart)
    }

    /// Construct directly with a pre-built chain context. Useful for tests and advanced
    /// embedding scenarios where the consumer manages provider lifecycle themselves.
    public init(
        policy: MultisigPolicy,
        chainContext: any ChainContext,
        stakingPart: StakingPart? = nil
    ) throws {
        self.policy = policy
        self.chainContext = chainContext
        self._address = try policy.paymentAddress(stakingPart: stakingPart)
    }

    /// The script address this wallet observes. Includes whatever staking part was supplied
    /// at init time (defaults to enterprise — payment-only).
    public nonisolated var address: Address { _address }

    /// All UTxOs currently locked at the multisig address. Always a fresh chain query — there
    /// is no caching layer (see the actor's docstring for rationale).
    public func utxos() async throws -> [UTxO] {
        do {
            return try await chainContext.utxos(address: _address)
        } catch {
            throw WalletError.wrappingProvider(error)
        }
    }

    /// Aggregate balance across the script address. Multisig vaults don't track stake
    /// rewards through this entry point — `rewards` is always 0. Use a separate
    /// `chainContext.stakeAddressInfo(...)` call against the vault's reward address if you
    /// need that.
    public func balance() async throws -> WalletBalance {
        let allUtxos = try await utxos()
        let lovelace = allUtxos.reduce(0) { $0 + $1.output.amount.coin }
        var assets = MultiAsset([:])
        for u in allUtxos {
            assets += u.output.amount.multiAsset
        }
        return WalletBalance(
            lovelace: lovelace,
            multiAsset: assets,
            rewards: 0,
            utxoCount: allUtxos.count
        )
    }

    /// Escape hatch: direct access to the underlying ChainContext (e.g. for callers that
    /// want to drive `TxBuilder` directly with the multisig address as an input).
    public nonisolated func chainContextHandle() -> any ChainContext {
        chainContext
    }

    // MARK: - Build

    /// Build (but do not sign or submit) a transaction sending `lovelace` from the multisig
    /// vault to `to`. Change is returned to the same multisig address.
    ///
    /// The resulting ``PreparedMultisigTransaction`` already carries the policy's native
    /// script in its witness set. Distribute its CBOR (``PreparedMultisigTransaction/exportCBOR()``
    /// + ``PreparedMultisigTransaction/bodyHash``) to cosigners; collect their
    /// ``PartialWitness`` returns; then call ``PreparedMultisigTransaction/combine(_:)``.
    public func prepareSend(
        lovelace: Int,
        to address: Address
    ) async throws -> PreparedMultisigTransaction {
        let utxoList = try await utxos()
        guard !utxoList.isEmpty else {
            throw WalletError.insufficientFunds(required: UInt64(lovelace), available: 0)
        }

        let context = chainContext
        let builder = TxBuilder(context: context)

        // Conservatively over-estimate the witness count for fee math. The coordinator could
        // pass a custom override; for v0.1.0 we use the policy's `requiredSignerCount()`.
        let required = policy.requiredSignerCount()
        builder.witnessOverride = max(1, required)

        // Tell the builder which scripts will witness the script-locked inputs. Without this
        // it has no way to know the policy and `buildWitnessSet()` would emit an empty
        // `nativeScripts`.
        builder.nativeScripts = [policy.nativeScript]
        builder.potentialInputs = utxoList

        try builder.addOutput(
            TransactionOutput(address: address, amount: Value(coin: lovelace))
        )

        let body: TransactionBody
        do {
            body = try await builder.build(changeAddress: _address)
        } catch {
            let total = utxoList.reduce(0) { $0 + $1.output.amount.coin }
            if total < lovelace {
                throw WalletError.insufficientFunds(
                    required: UInt64(lovelace),
                    available: UInt64(max(0, total))
                )
            }
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

        return PreparedMultisigTransaction(
            transaction: unsigned,
            policy: policy,
            chainContext: context
        )
    }
}
