import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

/// Wallet backed by `cardano-cli`-style `.skey` files. Useful when keys have been
/// generated outside the app — e.g. by an offline ceremony or migrated from an existing
/// `cardano-cli` setup.
///
/// Backed by a ``TextEnvelopeKeyManager``. Single-address (CLI keys are flat, not HD); no
/// gap-limit sweep. Full send / sign capability since the key files contain the signing
/// material.
public actor TextEnvelopeWallet: WalletProtocol {

    public nonisolated let network: Network
    public nonisolated let account: Account
    public nonisolated let kind: WalletKind = .textEnvelope
    public nonisolated let keyManager: KeyManager

    private nonisolated let chainContext: any ChainContext
    private nonisolated let _address: Address
    private nonisolated let _rewardAddress: Address?

    /// Build from `.skey` file URLs.
    public init(
        paymentKeyFile: URL,
        stakeKeyFile: URL? = nil,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws {
        let km = try TextEnvelopeKeyManager(
            paymentKeyFile: paymentKeyFile,
            stakeKeyFile: stakeKeyFile
        )
        try await self.init(
            keyManager: km,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
    }

    /// Build from a pre-constructed ``TextEnvelopeKeyManager`` (typed-keys variant or
    /// path-based variant — either works).
    public init(
        keyManager: TextEnvelopeKeyManager,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws {
        if case .custom = provider {
            // skip
        } else if provider.network != network {
            throw WalletError.configurationMissing(
                "Provider network \(provider.network) does not match wallet network \(network)."
            )
        }
        let context = try await ProviderFactory.make(provider)
        try await self.init(
            keyManager: keyManager,
            network: network,
            chainContext: context,
            accountIndex: accountIndex
        )
    }

    /// Test-friendly init: takes a pre-built `ChainContext` directly.
    public init(
        keyManager: TextEnvelopeKeyManager,
        network: Network,
        chainContext: any ChainContext,
        accountIndex: UInt32 = 0
    ) async throws {
        let account = Account(index: accountIndex, network: network)
        let path = account.paymentPath()
        let pVKey = try await keyManager.paymentVerificationKey(at: path)
        let sVKey = try? await keyManager.stakeVerificationKey(at: account.stakePath())

        let primary: Address
        let reward: Address?
        if let sVKey {
            primary = try Address(
                paymentPart: .verificationKeyHash(try pVKey.hash()),
                stakingPart: .verificationKeyHash(try sVKey.hash()),
                network: network.networkId
            )
            reward = try Address(
                stakingPart: .verificationKeyHash(try sVKey.hash()),
                network: network.networkId
            )
        } else {
            primary = try Address(
                paymentPart: .verificationKeyHash(try pVKey.hash()),
                network: network.networkId
            )
            reward = nil
        }

        self.network = network
        self.account = account
        self.keyManager = keyManager
        self.chainContext = chainContext
        self._address = primary
        self._rewardAddress = reward
    }

    // MARK: - WalletProtocol

    public func receiveAddress() async throws -> Address { _address }
    public func changeAddress() async throws -> Address { _address }

    public func rewardAddress() async throws -> Address {
        guard let reward = _rewardAddress else {
            throw WalletError.configurationMissing(
                "TextEnvelopeWallet has no stake key; no reward address available."
            )
        }
        return reward
    }

    public func utxos() async throws -> [UTxO] {
        do {
            return try await chainContext.utxos(address: _address)
        } catch {
            throw WalletError.wrappingProvider(error)
        }
    }

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

    public nonisolated func chainContextHandle() -> any ChainContext { chainContext }

    // MARK: - Send

    /// Build an unsigned send transaction.
    public func prepareSend(lovelace: Int, to address: Address) async throws -> PreparedTransaction {
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

        return PreparedTransaction(
            transaction: unsigned,
            signingPaths: [account.paymentPath()],
            chainContext: context,
            keyManager: keyManager
        )
    }

    /// One-shot: build, sign, submit.
    @discardableResult
    public func send(lovelace: Int, to address: Address) async throws -> String {
        let prepared = try await prepareSend(lovelace: lovelace, to: address)
        let signed = try await prepared.sign()
        return try await signed.submit()
    }
}
