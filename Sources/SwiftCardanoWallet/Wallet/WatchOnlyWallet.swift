import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

/// Wallet that holds only verification keys — useful for monitoring an address you don't
/// own, or for the warm side of an offline-signing workflow (build the unsigned
/// transaction here, ship the CBOR to a cold machine that owns the signing keys).
///
/// Backed by a ``WatchOnlyKeyManager``. Constructing a ``PreparedTransaction`` via
/// ``prepareSend(lovelace:to:)`` succeeds, but calling
/// ``PreparedTransaction/sign()`` will throw ``WalletError/watchOnly`` — that's the
/// signal to hand off to whichever offline signer owns the keys.
///
/// Unlike ``MnemonicWallet``, the watch-only wallet observes a **single** address (the
/// one derived from the supplied verification keys). There's no gap-limit sweep — the
/// caller has explicitly told us which address to watch.
public actor WatchOnlyWallet: WalletProtocol {

    public nonisolated let network: Network
    public nonisolated let account: Account
    public nonisolated let kind: WalletKind = .watchOnly
    public nonisolated let keyManager: KeyManager

    private nonisolated let chainContext: any ChainContext
    /// The payment-capable address we observe UTxOs at. `nil` when the wallet was
    /// constructed from a reward-only (`stake1…`) address — stake addresses don't hold
    /// UTxOs, so `utxos()` returns an empty list in that mode.
    private nonisolated let _address: Address?
    /// The reward (stake) address, if we know one. Set when:
    /// - vkey-based construction supplied a stake verification key, or
    /// - address-based construction was given a reward address directly, or
    /// - address-based construction was given a payment address whose staking part is
    ///   a vkey hash (we can rebuild the reward address from the staking credential).
    private nonisolated let _rewardAddress: Address?

    /// Build from already-parsed verification keys.
    public init(
        paymentVerificationKey: PaymentVerificationKey,
        stakeVerificationKey: StakeVerificationKey? = nil,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws {
        try await self.init(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: paymentVerificationKey,
                stakeVerificationKey: stakeVerificationKey
            ),
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
    }

    /// Build by loading verification keys from `cardano-cli` `.vkey` TextEnvelope files.
    public init(
        paymentVKeyFile: URL,
        stakeVKeyFile: URL? = nil,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws {
        let pVKey: PaymentVerificationKey
        do {
            pVKey = try PaymentVerificationKey.load(from: paymentVKeyFile.path)
        } catch {
            throw WalletError.configurationMissing(
                "Failed to load payment vkey from '\(paymentVKeyFile.path)': \(error)"
            )
        }
        let sVKey: StakeVerificationKey?
        if let stakeVKeyFile {
            do {
                sVKey = try StakeVerificationKey.load(from: stakeVKeyFile.path)
            } catch {
                throw WalletError.configurationMissing(
                    "Failed to load stake vkey from '\(stakeVKeyFile.path)': \(error)"
                )
            }
        } else {
            sVKey = nil
        }
        try await self.init(
            paymentVerificationKey: pVKey,
            stakeVerificationKey: sVKey,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
    }

    /// Test-friendly init: takes a pre-built `KeyManager` + chain context directly.
    /// Production callers use the provider-driven inits above.
    public init(
        keyManager: WatchOnlyKeyManager,
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
        try self.init(
            keyManager: keyManager,
            network: network,
            chainContext: context,
            accountIndex: accountIndex
        )
    }

    /// Build from a Cardano ``SwiftCardanoCore/Address`` you already know. Accepts:
    ///
    /// - **Base / enterprise addresses** — observe UTxOs at this address. If the address
    ///   has a vkey-hash staking part, the matching reward address is derived
    ///   automatically; if the staking part is a script hash or absent,
    ///   ``rewardAddress()`` throws.
    /// - **Reward / stake addresses** (`stake1…`) — observe stake info only.
    ///   ``utxos()`` returns an empty list (reward addresses don't hold UTxOs); use the
    ///   underlying ``chainContextHandle()`` plus `stakeAddressInfo(address:)` to read
    ///   rewards / delegation status.
    ///
    /// No verification keys are required — useful for monitoring tools that only know an
    /// address. Every signing path throws ``WalletError/unsupportedOperation(_:)``;
    /// ``prepareSend(lovelace:to:)`` still works for the build-unsigned half of an
    /// offline-signing workflow.
    public init(
        address: Address,
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
        try self.init(
            address: address,
            network: network,
            chainContext: context,
            accountIndex: accountIndex
        )
    }

    /// Test-friendly variant of ``init(address:network:provider:accountIndex:)``.
    public init(
        address: Address,
        network: Network,
        chainContext: any ChainContext,
        accountIndex: UInt32 = 0
    ) throws {
        let account = Account(index: accountIndex, network: network)

        // Classify the supplied address.
        let observable: Address?  // for UTxO queries
        let reward: Address?

        switch (address.paymentPart, address.stakingPart) {

        case (.some, .some(.verificationKeyHash(let stakeHash))):
            // Base address with vkey-hash stake → both observable and reward derivable.
            observable = address
            do {
                reward = try Address(
                    stakingPart: .verificationKeyHash(stakeHash),
                    network: network.networkId
                )
            } catch {
                throw WalletError.derivationFailed(
                    "Failed to derive reward address from staking part: \(error)"
                )
            }

        case (.some, .some(.scriptHash)), (.some, .some(.pointerAddress)), (.some, .none):
            // Enterprise / base-with-script-stake / pointer addresses: payment-capable
            // but no reward address we can hand out (pointer-style delegations are still
            // valid on-chain but we don't expose a stake credential helper for them yet).
            observable = address
            reward = nil

        case (.none, .some):
            // Reward address only (`stake1…`).
            observable = nil
            reward = address

        case (.none, .none):
            throw WalletError.configurationMissing(
                "WatchOnlyWallet: supplied address has neither a payment nor a staking part."
            )
        }

        self.network = network
        self.account = account
        self.keyManager = WatchOnlyKeyManager()  // blind — no vkeys
        self.chainContext = chainContext
        self._address = observable
        self._rewardAddress = reward
    }

    /// Test-friendly init that bypasses `ProviderFactory`.
    public init(
        keyManager: WatchOnlyKeyManager,
        network: Network,
        chainContext: any ChainContext,
        accountIndex: UInt32 = 0
    ) throws {
        let account = Account(index: accountIndex, network: network)
        let path = account.paymentPath()
        let pVKey = try keyManager.paymentVerificationKey(at: path)
        // Stake VK is optional — we derive an enterprise address if absent.
        let sVKey = try? keyManager.stakeVerificationKey(at: account.stakePath())

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

    public func receiveAddress() async throws -> Address {
        guard let address = _address else {
            throw WalletError.configurationMissing(
                "WatchOnlyWallet was constructed from a reward-only stake address; no payment receive address available."
            )
        }
        return address
    }

    public func changeAddress() async throws -> Address {
        try await receiveAddress()
    }

    public func rewardAddress() async throws -> Address {
        guard let reward = _rewardAddress else {
            throw WalletError.configurationMissing(
                "WatchOnlyWallet has no known staking credential; no reward address available."
            )
        }
        return reward
    }

    public func utxos() async throws -> [UTxO] {
        // Reward-only mode: stake addresses never hold UTxOs.
        guard let address = _address else { return [] }
        do {
            return try await chainContext.utxos(address: address)
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

    // MARK: - Build (unsigned)

    /// Build an unsigned send transaction. Useful for offline-signing flows: the cold
    /// machine holds the matching ``MnemonicWallet`` (or `.skey` files) and consumes
    /// ``PreparedTransaction/exportCBOR()`` to sign + submit.
    ///
    /// Calling ``PreparedTransaction/sign()`` on the result will throw
    /// ``WalletError/watchOnly`` — that's expected; you're meant to hand off.
    ///
    /// Throws ``WalletError/configurationMissing(_:)`` when called on a wallet
    /// constructed from a reward-only stake address (no payment credential → no UTxOs to
    /// spend).
    public func prepareSend(lovelace: Int, to address: Address) async throws -> PreparedTransaction {
        guard let observable = _address else {
            throw WalletError.configurationMissing(
                "Cannot prepareSend from a reward-only WatchOnlyWallet; stake addresses don't hold UTxOs."
            )
        }
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
            body = try await builder.build(changeAddress: observable)
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

        // We supply a single signing path even though signing will fail — gives the
        // PreparedTransaction enough metadata to be useful (CBOR export, hand-off).
        return PreparedTransaction(
            transaction: unsigned,
            signingPaths: [account.paymentPath()],
            chainContext: context,
            keyManager: keyManager
        )
    }
}
