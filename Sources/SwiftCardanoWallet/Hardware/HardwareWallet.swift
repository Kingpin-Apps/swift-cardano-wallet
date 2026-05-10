import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder
import SwiftCardanoUtils

/// Wallet whose private keys live on a Ledger / Trezor device. Operates the device through
/// `swift-cardano-utils`'s ``CardanoHWCLI`` wrapper (which shells out to `cardano-hw-cli`),
/// so this type **requires the user to have `cardano-hw-cli` installed** when they call
/// ``PreparedHardwareTransaction/signWithDevice()``.
///
/// On iOS the hardware flow is impossible (no shell-out); ``init`` traps with
/// ``WalletError/unsupportedOperation(_:)`` so consumers can detect support at construction.
///
/// Two-tier signing API on the prepared transaction:
/// - **Manual flow** — ``PreparedHardwareTransaction/writeTxBody(to:)`` + caller-driven
///   `cardano-hw-cli` invocation + ``PreparedHardwareTransaction/attachWitnesses(fromFiles:)``.
///   Useful for offline signing on a separate machine.
/// - **Driven flow** — ``PreparedHardwareTransaction/signWithDevice()`` does the whole
///   sequence (autocorrect → start device → witness → assemble) in one call. Requires the
///   wallet to have been constructed with a ``CardanoHWCLI`` injected.
public actor HardwareWallet {

    public nonisolated let network: Network
    public nonisolated let kind: WalletKind = .hardware

    public nonisolated let payment: HardwareKeyFile
    public nonisolated let stake: HardwareKeyFile?

    private nonisolated let chainContext: any ChainContext
    private nonisolated let _address: Address
    private nonisolated let _hwcli: CardanoHWCLI?

    /// Construct from a chain provider and one (or two) hardware key file pairs.
    ///
    /// - Parameters:
    ///   - payment: Required payment-role hardware key file.
    ///   - stake: Optional stake-role hardware key file. If supplied, addresses are
    ///     **base** addresses (payment + stake credential); otherwise they're
    ///     **enterprise** (payment-only).
    ///   - network: Wallet network. Used to derive the address and validate the provider.
    ///   - provider: Chain backend.
    ///   - hwcli: Optional pre-configured ``CardanoHWCLI``. Only required for the driven
    ///     ``PreparedHardwareTransaction/signWithDevice()`` path; the manual flow doesn't
    ///     need it.
    public init(
        payment: HardwareKeyFile,
        stake: HardwareKeyFile? = nil,
        network: Network,
        provider: ProviderConfig,
        hwcli: CardanoHWCLI? = nil
    ) async throws {
        #if os(iOS)
        throw WalletError.unsupportedOperation(
            "Hardware wallet signing requires shell-out to cardano-hw-cli, which is not available on iOS."
        )
        #else
        guard payment.role == .payment else {
            throw WalletError.configurationMissing(
                "HardwareWallet `payment` parameter must have role `.payment`, got \(payment.role)."
            )
        }
        if let stake, stake.role != .stake {
            throw WalletError.configurationMissing(
                "HardwareWallet `stake` parameter must have role `.stake`, got \(stake.role)."
            )
        }
        if case .custom = provider {
            // skip network sanity check
        } else if provider.network != network {
            throw WalletError.configurationMissing(
                "Provider network \(provider.network) does not match wallet network \(network)."
            )
        }

        let paymentHash = try payment.keyHash()
        let stakeHash = try stake?.keyHash()

        let address: Address
        do {
            if let stakeHash {
                address = try Address(
                    paymentPart: .verificationKeyHash(paymentHash),
                    stakingPart: .verificationKeyHash(stakeHash),
                    network: network.networkId
                )
            } else {
                address = try Address(
                    paymentPart: .verificationKeyHash(paymentHash),
                    stakingPart: nil,
                    network: network.networkId
                )
            }
        } catch {
            throw WalletError.derivationFailed("Failed to derive hardware-wallet address: \(error)")
        }

        self.network = network
        self.payment = payment
        self.stake = stake
        self.chainContext = try await ProviderFactory.make(provider)
        self._address = address
        self._hwcli = hwcli
        #endif
    }

    /// Test-friendly init that takes a pre-built chain context. Lets unit tests bypass
    /// `ProviderFactory` and inject a stub.
    public init(
        payment: HardwareKeyFile,
        stake: HardwareKeyFile? = nil,
        network: Network,
        chainContext: any ChainContext,
        hwcli: CardanoHWCLI? = nil
    ) throws {
        #if os(iOS)
        throw WalletError.unsupportedOperation(
            "Hardware wallet signing requires shell-out to cardano-hw-cli, which is not available on iOS."
        )
        #else
        guard payment.role == .payment else {
            throw WalletError.configurationMissing(
                "HardwareWallet `payment` parameter must have role `.payment`, got \(payment.role)."
            )
        }
        if let stake, stake.role != .stake {
            throw WalletError.configurationMissing(
                "HardwareWallet `stake` parameter must have role `.stake`, got \(stake.role)."
            )
        }

        let paymentHash = try payment.keyHash()
        let stakeHash = try stake?.keyHash()

        let address: Address
        do {
            if let stakeHash {
                address = try Address(
                    paymentPart: .verificationKeyHash(paymentHash),
                    stakingPart: .verificationKeyHash(stakeHash),
                    network: network.networkId
                )
            } else {
                address = try Address(
                    paymentPart: .verificationKeyHash(paymentHash),
                    stakingPart: nil,
                    network: network.networkId
                )
            }
        } catch {
            throw WalletError.derivationFailed("Failed to derive hardware-wallet address: \(error)")
        }

        self.network = network
        self.payment = payment
        self.stake = stake
        self.chainContext = chainContext
        self._address = address
        self._hwcli = hwcli
        #endif
    }

    /// The address this hardware wallet observes. `base` if a stake key file was supplied,
    /// `enterprise` otherwise.
    public nonisolated var address: Address { _address }

    public nonisolated func chainContextHandle() -> any ChainContext { chainContext }

    /// All UTxOs at the wallet's address. Always a fresh chain query — no cache.
    public func utxos() async throws -> [UTxO] {
        do {
            return try await chainContext.utxos(address: _address)
        } catch {
            throw WalletError.wrappingProvider(error)
        }
    }

    /// Aggregate balance at the wallet's address.
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

    /// Build (but do not sign) a transaction. Witness count is auto-set to match the
    /// wallet's signer count (1 if payment-only, 2 if both payment + stake key files were
    /// provided — Cardano's stake credential always co-signs alongside payment for
    /// base-address spends only when the stake credential is part of a stake-related
    /// action; for plain `prepareSend` we override to 1 and let coin selection account for
    /// fees on the lighter side).
    public func prepareSend(
        lovelace: Int,
        to address: Address
    ) async throws -> PreparedHardwareTransaction {
        let utxoList = try await utxos()
        guard !utxoList.isEmpty else {
            throw WalletError.insufficientFunds(required: UInt64(lovelace), available: 0)
        }

        let context = chainContext
        let builder = TxBuilder(context: context)
        builder.witnessOverride = 1
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

        return PreparedHardwareTransaction(
            transaction: unsigned,
            payment: payment,
            stake: stake,
            chainContext: context,
            hwcli: _hwcli
        )
    }
}
