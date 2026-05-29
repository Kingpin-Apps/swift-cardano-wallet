import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftMnemonic

/// HD wallet rooted in a BIP-39 mnemonic, querying / submitting through a chain provider.
///
/// UTxOs and balance are served through a ``BalanceTracker`` that sweeps the receive and change
/// roles up to a configurable gap limit (default 20). The first call to ``utxos()`` /
/// ``balance()`` triggers the initial sweep; subsequent calls return the cached snapshot.
/// Force a refresh with ``refresh()`` (e.g. after submitting a tx).
public actor MnemonicWallet: WalletProtocol {

    public nonisolated let network: Network
    public nonisolated let account: Account
    public nonisolated let kind: WalletKind = .mnemonic
    public nonisolated let keyManager: KeyManager
    private nonisolated let chainContext: any ChainContext
    private nonisolated let _handleResolver: (any HandleResolver)?

    private let tracker: BalanceTracker

    /// Construct from a mnemonic phrase and a provider config.
    ///
    /// - Parameters:
    ///   - mnemonic: 12 / 15 / 18 / 21 / 24 word phrase.
    ///   - network: target network (must agree with `provider.network` for non-`custom` providers).
    ///   - provider: chain backend.
    ///   - passphrase: optional BIP-39 passphrase.
    ///   - accountIndex: CIP-1852 account index (default 0).
    ///   - utxoStore: where the ``BalanceTracker`` caches UTxOs. Defaults to
    ///     ``InMemoryUTxOStore``; pass a `SQLiteUTxOStore` (PR 10) or any other ``UTxOStore``
    ///     for durable caching.
    ///   - gapLimit: how far the address sweep walks ahead with no activity before stopping
    ///     (per role). Default 20 — the BIP-44 standard.
    ///   - handleResolver: optional ``HandleResolver`` enabling ``resolveHandle(_:)`` /
    ///     ``sendTo(handle:lovelace:)``. If `nil`, those methods throw
    ///     ``WalletError/configurationMissing(_:)``. Pass a ``DefaultHandleResolver`` for
    ///     mainnet wallets, or your own mock/proxy implementation.
    public init(
        mnemonic: String,
        network: Network,
        provider: ProviderConfig,
        passphrase: String = "",
        accountIndex: UInt32 = 0,
        utxoStore: UTxOStore? = nil,
        gapLimit: UInt32 = 20,
        handleResolver: (any HandleResolver)? = nil
    ) async throws {
        if case .custom = provider {
            // skip the network sanity check for custom providers
        } else if provider.network != network {
            throw WalletError.configurationMissing(
                "Provider network \(provider.network) does not match wallet network \(network)."
            )
        }

        let acct = Account(index: accountIndex, network: network)
        let km = try MnemonicKeyManager(mnemonic: mnemonic, passphrase: passphrase)
        let ctx = try await ProviderFactory.make(provider)

        self.network = network
        self.account = acct
        self.keyManager = km
        self.chainContext = ctx
        self._handleResolver = handleResolver
        self.tracker = BalanceTracker(
            account: acct,
            keyManager: km,
            chainContext: ctx,
            store: utxoStore ?? InMemoryUTxOStore(),
            gapLimit: gapLimit
        )
    }

    // MARK: - Wallet conformance

    public func receiveAddress() async throws -> Address {
        try await account.address(with: keyManager, role: .external, index: 0)
    }

    public func changeAddress() async throws -> Address {
        try await account.address(with: keyManager, role: .change, index: 0)
    }

    public func rewardAddress() async throws -> Address {
        try await account.rewardAddress(with: keyManager)
    }

    public func utxos() async throws -> [UTxO] {
        try await tracker.utxos()
    }

    public func balance() async throws -> WalletBalance {
        try await tracker.balance()
    }

    /// Force a chain re-sweep into the UTxO cache. Call after a successful submit if you
    /// want subsequent ``balance()`` / ``utxos()`` calls to reflect the new state.
    public func refresh() async throws {
        try await tracker.refresh()
    }

    /// Escape hatch: direct access to the underlying tracker for advanced sync workflows.
    public func balanceTracker() -> BalanceTracker { tracker }

    /// Escape hatch: callers needing direct ChainContext access (e.g. for advanced tx-building
    /// or features not yet surfaced) can read the underlying context.
    public nonisolated func chainContextHandle() -> any ChainContext {
        chainContext
    }

    /// The handle resolver supplied at init, if any. Returns `nil` if the wallet was
    /// constructed without one.
    public nonisolated var handleResolver: (any HandleResolver)? {
        _handleResolver
    }

    // MARK: - Generation

    /// Generate a fresh BIP-39 phrase and build a ``MnemonicWallet`` around it.
    ///
    /// The returned ``GeneratedMnemonicWallet`` value carries the **fresh phrase** alongside
    /// the wallet — you must persist (or display to the user for backup) the phrase before
    /// the value goes out of scope. Once it's gone, the phrase is unrecoverable.
    ///
    /// ```swift
    /// let generated = try await MnemonicWallet.generate(
    ///     network: .mainnet,
    ///     provider: .blockfrost(projectId: "mainnet_…")
    /// )
    /// userDefaults.showBackupSheet(phrase: generated.phrase)   // hand to user, then forget
    /// let wallet = generated.wallet
    /// ```
    ///
    /// - Parameters:
    ///   - wordCount: 12, 15, 18, 21, or 24. Defaults to 24 (256 bits of entropy — the
    ///     BIP-39 maximum). Anything else throws ``WalletError/configurationMissing(_:)``.
    ///   - network: target Cardano network.
    ///   - provider: chain backend.
    ///   - passphrase: optional BIP-39 passphrase ("25th word"). Empty by default.
    ///   - accountIndex: CIP-1852 account index. Default 0.
    ///   - utxoStore: see ``init(mnemonic:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)``.
    ///   - gapLimit: see init.
    ///   - handleResolver: see init.
    public static func generate(
        wordCount: Int = 24,
        network: Network,
        provider: ProviderConfig,
        passphrase: String = "",
        accountIndex: UInt32 = 0,
        utxoStore: UTxOStore? = nil,
        gapLimit: UInt32 = 20,
        handleResolver: (any HandleResolver)? = nil
    ) async throws -> GeneratedMnemonicWallet {
        guard let wc = WordCount(rawValue: wordCount) else {
            throw WalletError.configurationMissing(
                "wordCount must be 12, 15, 18, 21, or 24; got \(wordCount)."
            )
        }
        let words: [String]
        do {
            words = try HDWallet.generateMnemonic(language: .english, wordCount: wc)
        } catch {
            throw WalletError.derivationFailed("mnemonic generation failed: \(error)")
        }
        let phrase = words.joined(separator: " ")

        let wallet = try await MnemonicWallet(
            mnemonic: phrase,
            network: network,
            provider: provider,
            passphrase: passphrase,
            accountIndex: accountIndex,
            utxoStore: utxoStore,
            gapLimit: gapLimit,
            handleResolver: handleResolver
        )
        return GeneratedMnemonicWallet(wallet: wallet, phrase: phrase)
    }
}

/// Carries a freshly-generated mnemonic alongside the wallet it built. **The phrase is
/// the only path to recovering this wallet** — display it to the user (so they can write
/// it down) or persist it via an ``EncryptedKeyManager`` / ``KeyStore`` before this value
/// goes out of scope.
///
/// `entropy` is the raw seed material the phrase encodes (16 / 20 / 24 / 28 / 32 bytes for
/// 12 / 15 / 18 / 21 / 24 word counts). Equivalent to the phrase as far as wallet
/// recovery is concerned; offered for callers that prefer to store the binary form.
public struct GeneratedMnemonicWallet: Sendable {
    public let wallet: MnemonicWallet
    public let phrase: String

    /// Raw entropy backing ``phrase``. Lazily decoded from the phrase on demand.
    public var entropy: Data {
        // BIP-39 phrase → entropy is deterministic and cheap; decode on read so
        // callers that only care about `phrase` don't pay anything.
        do {
            let words = phrase.split(separator: " ").map(String.init)
            return try Mnemonic.toEntropy(words, wordlist: Language.english.words())
        } catch {
            // Phrase came from HDWallet.generateMnemonic; if decoding fails here the
            // upstream invariant is broken — surface a recognizable empty value rather
            // than crashing.
            return Data()
        }
    }

    public init(wallet: MnemonicWallet, phrase: String) {
        self.wallet = wallet
        self.phrase = phrase
    }
}
