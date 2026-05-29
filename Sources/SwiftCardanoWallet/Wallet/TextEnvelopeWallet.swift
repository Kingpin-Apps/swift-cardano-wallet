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
    public func prepareSend(lovelace: Int64, to address: Address) async throws -> PreparedTransaction {
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
    public func send(lovelace: Int64, to address: Address) async throws -> String {
        let prepared = try await prepareSend(lovelace: lovelace, to: address)
        let signed = try await prepared.sign()
        return try await signed.submit()
    }

    // MARK: - Generation

    /// Generate a fresh non-extended Ed25519 payment + stake key pair, write them as
    /// `payment.skey` / `stake.skey` TextEnvelope files inside `directory`, and build a
    /// ``TextEnvelopeWallet`` around the new files. Matches the file layout produced by
    /// `cardano-cli address key-gen` so the resulting `.skey`s drop into any existing
    /// `cardano-cli`-based toolchain.
    ///
    /// ```swift
    /// let generated = try await TextEnvelopeWallet.generate(
    ///     writeTo: keyDirectory,
    ///     network: .preprod,
    ///     provider: .blockfrost(projectId: "preprod_…")
    /// )
    /// print("Backed up to:", generated.paymentSkeyURL.path, generated.stakeSkeyURL.path)
    /// ```
    ///
    /// - Parameters:
    ///   - directory: where to write the `.skey` files. Created if it doesn't exist.
    ///   - network: target Cardano network.
    ///   - provider: chain backend.
    ///   - accountIndex: stored on the wallet's ``Account`` for parity with HD wallets;
    ///     CLI keys are flat so the index does not influence the derived address.
    ///   - overwrite: if `false` (default) and either file already exists in
    ///     `directory`, throws ``WalletError/keystore(_:)``.
    public static func generate(
        writeTo directory: URL,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0,
        overwrite: Bool = false
    ) async throws -> GeneratedTextEnvelopeWallet {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let paymentURL = directory.appendingPathComponent("payment.skey")
        let stakeURL = directory.appendingPathComponent("stake.skey")
        if !overwrite {
            if fm.fileExists(atPath: paymentURL.path) {
                throw WalletError.keystore("Refusing to overwrite existing payment.skey at \(paymentURL.path)")
            }
            if fm.fileExists(atPath: stakeURL.path) {
                throw WalletError.keystore("Refusing to overwrite existing stake.skey at \(stakeURL.path)")
            }
        }

        let paymentKeyPair: PaymentKeyPair
        let stakeKeyPair: StakeKeyPair
        do {
            paymentKeyPair = try PaymentKeyPair.generate()
            stakeKeyPair = try StakeKeyPair.generate()
        } catch {
            throw WalletError.derivationFailed("TextEnvelope key generation failed: \(error)")
        }

        do {
            try paymentKeyPair.signingKey.save(to: paymentURL.path, overwrite: overwrite)
            try stakeKeyPair.signingKey.save(to: stakeURL.path, overwrite: overwrite)
        } catch {
            throw WalletError.keystore("Failed to write generated .skey file: \(error)")
        }

        let wallet = try await TextEnvelopeWallet(
            paymentKeyFile: paymentURL,
            stakeKeyFile: stakeURL,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
        return GeneratedTextEnvelopeWallet(
            wallet: wallet,
            paymentSkeyURL: paymentURL,
            stakeSkeyURL: stakeURL
        )
    }

    /// Generate fresh keys and build the wallet without persisting anything to disk.
    /// The raw 32-byte signing key payloads are returned alongside the wallet so the
    /// caller can persist them via their own ``KeyStore`` or pipe them through encryption.
    ///
    /// Use this when you want full control over how the keys are stored — e.g.
    /// hand them to a custom ``KeyStore`` that stores them in the iOS keychain rather
    /// than on the filesystem.
    public static func generateInMemory(
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws -> GeneratedInMemoryTextEnvelopeWallet {
        let paymentKeyPair: PaymentKeyPair
        let stakeKeyPair: StakeKeyPair
        do {
            paymentKeyPair = try PaymentKeyPair.generate()
            stakeKeyPair = try StakeKeyPair.generate()
        } catch {
            throw WalletError.derivationFailed("TextEnvelope key generation failed: \(error)")
        }

        let paymentPayload = paymentKeyPair.signingKey.payload
        let stakePayload = stakeKeyPair.signingKey.payload

        let km = TextEnvelopeKeyManager(
            paymentPayload: paymentPayload,
            paymentIsExtended: false,
            stakePayload: stakePayload,
            stakeIsExtended: false
        )
        let wallet = try await TextEnvelopeWallet(
            keyManager: km,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
        return GeneratedInMemoryTextEnvelopeWallet(
            wallet: wallet,
            paymentSigningKeyPayload: paymentPayload,
            stakeSigningKeyPayload: stakePayload
        )
    }
}

/// Returned by ``TextEnvelopeWallet/generate(writeTo:network:provider:accountIndex:overwrite:)``.
/// Carries the on-disk paths of the freshly-written `.skey` files alongside the wallet.
public struct GeneratedTextEnvelopeWallet: Sendable {
    public let wallet: TextEnvelopeWallet
    public let paymentSkeyURL: URL
    public let stakeSkeyURL: URL
}

/// Returned by ``TextEnvelopeWallet/generateInMemory(network:provider:accountIndex:)``.
/// Carries the raw 32-byte Ed25519 signing-key payloads — persist them via your own
/// ``KeyStore`` before this value goes out of scope.
public struct GeneratedInMemoryTextEnvelopeWallet: Sendable {
    public let wallet: TextEnvelopeWallet
    public let paymentSigningKeyPayload: Data
    public let stakeSigningKeyPayload: Data
}
