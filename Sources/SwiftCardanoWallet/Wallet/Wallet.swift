import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
#if HARDWARE
import SwiftCardanoUtils
#endif
import SwiftMnemonic

/// Top-level handle for any wallet type shipped by `SwiftCardanoWallet`. Unifies
/// ``MnemonicWallet``, ``MultisigWallet``, and ``HardwareWallet`` behind one `Sendable`
/// value so apps can store "a wallet" without statically committing to one kind.
///
/// Three case constructors wrap an already-built concrete wallet:
///
/// ```swift
/// let mnemonic = try await MnemonicWallet(mnemonic: phrase, network: .mainnet, provider: ...)
/// let wallet: Wallet = .mnemonic(mnemonic)
/// ```
///
/// Three labeled factory methods build directly without going through the concrete type:
///
/// ```swift
/// let wallet = try await Wallet.mnemonic(
///     phrase: phrase,
///     network: .mainnet,
///     provider: .blockfrost(projectId: "mainnet_…")
/// )
/// ```
///
/// Common reads (``kind``, ``network``, ``primaryAddress()``, ``utxos()``, ``balance()``)
/// are available directly on the enum. For richer flows — coin selection, multi-step
/// signing, hardware device prompts — extract the concrete wallet via the typed
/// accessors (``mnemonicWallet``, ``multisigWallet``, ``hardwareWallet``).
public enum Wallet: Sendable {

    /// HD wallet backed by a BIP-39 mnemonic. Also the runtime that backs encrypted
    /// blobs once decrypted — there's no separate "encrypted wallet" case because
    /// encryption is a key-management concern (see ``EncryptedKeyManager``) rather than a
    /// runtime distinction. Use ``Wallet/encrypted(blob:passphrase:network:provider:)`` to
    /// build one of these from a stored ``EncryptedBlob``.
    case mnemonic(MnemonicWallet)

    /// Wallet backed by `cardano-cli`-style `.skey` files. Single address (CLI keys are
    /// flat, not HD); full send + sign.
    case textEnvelope(TextEnvelopeWallet)

    /// Read-only wallet — verification keys only. ``Wallet/send(lovelace:to:)`` and
    /// ``Wallet/sendTo(handle:lovelace:)`` throw ``WalletError/watchOnly``; use the
    /// concrete actor's `prepareSend` for offline-signing handoff workflows (the
    /// resulting CBOR can be signed by a separate wallet that owns the keys).
    case watchOnly(WatchOnlyWallet)

    /// Native-script multisig vault. Sibling type with its own ``PartialWitness`` flow.
    case multisig(MultisigWallet)

    /// Hardware wallet driven through `cardano-hw-cli`. macOS / Linux only; trait-gated.
    #if HARDWARE
    case hardware(HardwareWallet)
    #endif

    // MARK: - Common reads

    /// The kind of wallet this is. Cheap; no I/O.
    public var kind: WalletKind {
        switch self {
        case .mnemonic(let w): return w.kind
        case .textEnvelope(let w): return w.kind
        case .watchOnly(let w): return w.kind
        case .multisig(let w): return w.kind
        #if HARDWARE
        case .hardware(let w): return w.kind
        #endif
        }
    }

    /// The wallet's Cardano network (mainnet / preprod / preview).
    public var network: Network {
        switch self {
        case .mnemonic(let w): return w.network
        case .textEnvelope(let w): return w.network
        case .watchOnly(let w): return w.network
        case .multisig(let w): return w.policy.network
        #if HARDWARE
        case .hardware(let w): return w.network
        #endif
        }
    }

    /// The wallet's primary receive address.
    ///
    /// - For ``MnemonicWallet``: role-0 index-0 derivation (the canonical receive
    ///   address).
    /// - For ``TextEnvelopeWallet`` / ``WatchOnlyWallet``: the single address derived
    ///   from the configured keys (CLI keys are flat, not HD).
    /// - For ``MultisigWallet``: the script address that defines the vault.
    /// - For ``HardwareWallet``: the address derived from the configured key files.
    public func primaryAddress() async throws -> Address {
        switch self {
        case .mnemonic(let w): return try await w.receiveAddress()
        case .textEnvelope(let w): return try await w.receiveAddress()
        case .watchOnly(let w): return try await w.receiveAddress()
        case .multisig(let w): return w.address
        #if HARDWARE
        case .hardware(let w): return w.address
        #endif
        }
    }

    /// All UTxOs the wallet currently sees.
    ///
    /// - ``MnemonicWallet`` returns the ``BalanceTracker``-cached set across all derived
    ///   addresses (gap-limit sweep).
    /// - All other kinds query the chain context directly for their single address.
    public func utxos() async throws -> [UTxO] {
        switch self {
        case .mnemonic(let w): return try await w.utxos()
        case .textEnvelope(let w): return try await w.utxos()
        case .watchOnly(let w): return try await w.utxos()
        case .multisig(let w): return try await w.utxos()
        #if HARDWARE
        case .hardware(let w): return try await w.utxos()
        #endif
        }
    }

    /// Aggregate balance — lovelace, multi-asset, rewards (mnemonic only), UTxO count.
    public func balance() async throws -> WalletBalance {
        switch self {
        case .mnemonic(let w): return try await w.balance()
        case .textEnvelope(let w): return try await w.balance()
        case .watchOnly(let w): return try await w.balance()
        case .multisig(let w): return try await w.balance()
        #if HARDWARE
        case .hardware(let w): return try await w.balance()
        #endif
        }
    }

    /// Underlying chain context. Useful for escape-hatch ``TxBuilder`` usage.
    public func chainContext() -> any ChainContext {
        switch self {
        case .mnemonic(let w): return w.chainContextHandle()
        case .textEnvelope(let w): return w.chainContextHandle()
        case .watchOnly(let w): return w.chainContextHandle()
        case .multisig(let w): return w.chainContextHandle()
        #if HARDWARE
        case .hardware(let w): return w.chainContextHandle()
        #endif
        }
    }

    // MARK: - Typed accessors

    /// The wrapped ``MnemonicWallet`` or `nil`.
    public var mnemonicWallet: MnemonicWallet? {
        if case .mnemonic(let w) = self { return w }
        return nil
    }

    /// The wrapped ``TextEnvelopeWallet`` or `nil`.
    public var textEnvelopeWallet: TextEnvelopeWallet? {
        if case .textEnvelope(let w) = self { return w }
        return nil
    }

    /// The wrapped ``WatchOnlyWallet`` or `nil`.
    public var watchOnlyWallet: WatchOnlyWallet? {
        if case .watchOnly(let w) = self { return w }
        return nil
    }

    /// The wrapped ``MultisigWallet`` or `nil`.
    public var multisigWallet: MultisigWallet? {
        if case .multisig(let w) = self { return w }
        return nil
    }

    #if HARDWARE
    /// The wrapped ``HardwareWallet`` or `nil`.
    public var hardwareWallet: HardwareWallet? {
        if case .hardware(let w) = self { return w }
        return nil
    }
    #endif

    /// `true` if this wallet kind can produce signatures locally. Watch-only wallets
    /// return `false`; everything else returns `true` (multisig / hardware sign through
    /// their own flows but `canSign` is `true` for the local participant).
    public var canSign: Bool {
        switch self {
        case .watchOnly: return false
        #if HARDWARE
        case .mnemonic, .textEnvelope, .multisig, .hardware: return true
        #else
        case .mnemonic, .textEnvelope, .multisig: return true
        #endif
        }
    }

    // MARK: - One-shot send

    /// Build, sign, and submit a send transaction. Returns the transaction id reported by
    /// the chain backend.
    ///
    /// - ``Wallet/mnemonic(_:)`` / ``Wallet/textEnvelope(_:)``: delegates to the
    ///   underlying actor's `send(lovelace:to:)`.
    /// - ``Wallet/watchOnly(_:)``: throws ``WalletError/watchOnly`` — call
    ///   `watchOnlyWallet?.prepareSend(...)` and hand the resulting CBOR to a separate
    ///   signer.
    /// - ``Wallet/multisig(_:)`` / ``Wallet/hardware(_:)``: throws
    ///   ``WalletError/unsupportedOperation(_:)`` because those require cosigner
    ///   coordination or device interaction that can't be hidden behind a single call.
    ///   Extract the concrete wallet via ``multisigWallet`` / ``hardwareWallet`` and use
    ///   its `prepareSend(...)` + signing flow.
    @discardableResult
    public func send(lovelace: Int64, to address: Address) async throws -> String {
        switch self {
        case .mnemonic(let w):
            return try await w.send(lovelace: lovelace, to: address)
        case .textEnvelope(let w):
            return try await w.send(lovelace: lovelace, to: address)
        case .watchOnly:
            throw WalletError.watchOnly
        case .multisig:
            throw WalletError.unsupportedOperation(
                "Multisig sends need cosigner partial witnesses. Use `wallet.multisigWallet?.prepareSend(...)` then collect and combine PartialWitnesses."
            )
        #if HARDWARE
        case .hardware:
            throw WalletError.unsupportedOperation(
                "Hardware wallet sends need device interaction. Use `wallet.hardwareWallet?.prepareSend(...)` then `signWithDevice()` or `attachWitnesses(fromFiles:)`."
            )
        #endif
        }
    }

    /// Resolve an ADA Handle then `send`. Forwards to
    /// ``MnemonicWallet/sendTo(handle:lovelace:)`` for mnemonic wallets; throws for
    /// the other kinds.
    @discardableResult
    public func sendTo(handle: String, lovelace: Int64) async throws -> String {
        switch self {
        case .mnemonic(let w):
            return try await w.sendTo(handle: handle, lovelace: lovelace)
        case .watchOnly:
            throw WalletError.watchOnly
        #if HARDWARE
        case .textEnvelope, .multisig, .hardware:
            throw WalletError.unsupportedOperation(
                "sendTo(handle:) is only wired up for mnemonic wallets in v0.1.0. Resolve the handle yourself via DefaultHandleResolver and pass the resulting Address to the concrete wallet's prepareSend."
            )
        #else
        case .textEnvelope, .multisig:
            throw WalletError.unsupportedOperation(
                "sendTo(handle:) is only wired up for mnemonic wallets in v0.1.0. Resolve the handle yourself via DefaultHandleResolver and pass the resulting Address to the concrete wallet's prepareSend."
            )
        #endif
        }
    }

    // MARK: - Convenience constructors

    /// Build a mnemonic-backed wallet and wrap it in the enum. Shorthand for
    /// ``MnemonicWallet/init(mnemonic:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)``
    /// + ``Wallet/mnemonic(_:)``.
    public static func mnemonic(
        phrase: String,
        network: Network,
        provider: ProviderConfig,
        passphrase: String = "",
        accountIndex: UInt32 = 0,
        utxoStore: UTxOStore? = nil,
        gapLimit: UInt32 = 20,
        handleResolver: (any HandleResolver)? = nil
    ) async throws -> Wallet {
        let w = try await MnemonicWallet(
            mnemonic: phrase,
            network: network,
            provider: provider,
            passphrase: passphrase,
            accountIndex: accountIndex,
            utxoStore: utxoStore,
            gapLimit: gapLimit,
            handleResolver: handleResolver
        )
        return .mnemonic(w)
    }

    /// Decrypt an ``EncryptedBlob`` (produced by ``EncryptedKeyManager``) and wrap the
    /// resulting mnemonic in a ``Wallet/mnemonic(_:)`` case. Useful when keys are
    /// persisted via a ``KeyStore``:
    ///
    /// ```swift
    /// let blob = try await store.load(id: "primary")
    /// let wallet = try await Wallet.encrypted(
    ///     blob: blob,
    ///     passphrase: userPassphrase,
    ///     network: .mainnet,
    ///     provider: .blockfrost(projectId: "mainnet_…")
    /// )
    /// // wallet.kind == .mnemonic — encryption is a key-management concern, not a
    /// // runtime distinction.
    /// ```
    public static func encrypted(
        blob: EncryptedBlob,
        passphrase: String,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0,
        utxoStore: UTxOStore? = nil,
        gapLimit: UInt32 = 20,
        handleResolver: (any HandleResolver)? = nil
    ) async throws -> Wallet {
        // Decrypt the blob → recover the underlying mnemonic → build a normal
        // MnemonicWallet around it. We don't keep the EncryptedKeyManager wrapper alive
        // because it forwards every call to its inner MnemonicKeyManager anyway.
        let decrypted = try await EncryptedKeyManager(blob: blob, passphrase: passphrase)
        let phrase = await decrypted.mnemonic
        let bip39 = await decrypted.bip39Passphrase
        return try await Self.mnemonic(
            phrase: phrase,
            network: network,
            provider: provider,
            passphrase: bip39,
            accountIndex: accountIndex,
            utxoStore: utxoStore,
            gapLimit: gapLimit,
            handleResolver: handleResolver
        )
    }

    /// Build a ``TextEnvelopeWallet`` from `.skey` files and wrap it.
    public static func textEnvelope(
        paymentKeyFile: URL,
        stakeKeyFile: URL? = nil,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws -> Wallet {
        let w = try await TextEnvelopeWallet(
            paymentKeyFile: paymentKeyFile,
            stakeKeyFile: stakeKeyFile,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
        return .textEnvelope(w)
    }

    /// Build a ``WatchOnlyWallet`` from verification keys and wrap it.
    public static func watchOnly(
        paymentVerificationKey: PaymentVerificationKey,
        stakeVerificationKey: StakeVerificationKey? = nil,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws -> Wallet {
        let w = try await WatchOnlyWallet(
            paymentVerificationKey: paymentVerificationKey,
            stakeVerificationKey: stakeVerificationKey,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
        return .watchOnly(w)
    }

    /// Build a ``WatchOnlyWallet`` from `.vkey` files and wrap it.
    public static func watchOnly(
        paymentVKeyFile: URL,
        stakeVKeyFile: URL? = nil,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws -> Wallet {
        let w = try await WatchOnlyWallet(
            paymentVKeyFile: paymentVKeyFile,
            stakeVKeyFile: stakeVKeyFile,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
        return .watchOnly(w)
    }

    /// Build a ``WatchOnlyWallet`` from a Cardano ``SwiftCardanoCore/Address`` you
    /// already know — no verification keys required. Accepts:
    ///
    /// - **Base / enterprise addresses** — observes UTxOs at this address.
    /// - **Reward / stake addresses** (`stake1…`) — observes stake info only;
    ///   ``Wallet/utxos()`` returns an empty list.
    ///
    /// Useful for monitoring tools that only know an address on-chain (block explorers,
    /// portfolio dashboards, accounting integrations).
    public static func watchOnly(
        address: Address,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0
    ) async throws -> Wallet {
        let w = try await WatchOnlyWallet(
            address: address,
            network: network,
            provider: provider,
            accountIndex: accountIndex
        )
        return .watchOnly(w)
    }

    /// Build a multisig vault and wrap it in the enum. The provider-based variant.
    public static func multisig(
        policy: MultisigPolicy,
        provider: ProviderConfig,
        stakingPart: StakingPart? = nil
    ) async throws -> Wallet {
        let w = try await MultisigWallet(
            policy: policy,
            provider: provider,
            stakingPart: stakingPart
        )
        return .multisig(w)
    }

    #if HARDWARE
    /// Build a hardware wallet (requires `cardano-hw-cli` for the device flow; the
    /// manual-flow path works without).
    public static func hardware(
        payment: HardwareKeyFile,
        stake: HardwareKeyFile? = nil,
        network: Network,
        provider: ProviderConfig,
        hwcli: CardanoHWCLI? = nil
    ) async throws -> Wallet {
        let w = try await HardwareWallet(
            payment: payment,
            stake: stake,
            network: network,
            provider: provider,
            hwcli: hwcli
        )
        return .hardware(w)
    }
    #endif

    // MARK: - Generation

    /// Generate a fresh BIP-39 phrase and return a ``Wallet/mnemonic(_:)`` along with the
    /// freshly-minted phrase. **Display or persist the phrase before this tuple goes out
    /// of scope** — once it's gone, the keys are unrecoverable.
    ///
    /// ```swift
    /// let (wallet, phrase) = try await Wallet.generateMnemonic(
    ///     network: .mainnet,
    ///     provider: .blockfrost(projectId: "mainnet_…")
    /// )
    /// backupSheet.show(phrase: phrase)
    /// ```
    ///
    /// - Parameters: see ``MnemonicWallet/generate(wordCount:language:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)``.
    public static func generateMnemonic(
        wordCount: Int = 24,
        language: Language = .english,
        network: Network,
        provider: ProviderConfig,
        passphrase: String = "",
        accountIndex: UInt32 = 0,
        utxoStore: UTxOStore? = nil,
        gapLimit: UInt32 = 20,
        handleResolver: (any HandleResolver)? = nil
    ) async throws -> (wallet: Wallet, phrase: String) {
        let generated = try await MnemonicWallet.generate(
            wordCount: wordCount,
            language: language,
            network: network,
            provider: provider,
            passphrase: passphrase,
            accountIndex: accountIndex,
            utxoStore: utxoStore,
            gapLimit: gapLimit,
            handleResolver: handleResolver
        )
        return (.mnemonic(generated.wallet), generated.phrase)
    }

    /// Generate a fresh BIP-39 phrase, encrypt it with `passphrase`, persist the result
    /// in a single round trip, and return a ``Wallet/mnemonic(_:)`` along with the
    /// encrypted blob (ready for ``KeyStore/save(_:id:)``) and the underlying phrase.
    /// The blob is the at-rest form; the phrase is the offline backup.
    ///
    /// ```swift
    /// let (wallet, phrase, blob) = try await Wallet.generateEncrypted(
    ///     passphrase: userPassphrase,
    ///     network: .mainnet,
    ///     provider: .blockfrost(projectId: "mainnet_…")
    /// )
    /// backupSheet.show(phrase: phrase)
    /// try await keyStore.save(blob, id: "primary")
    /// ```
    public static func generateEncrypted(
        passphrase: String,
        wordCount: Int = 24,
        language: Language = .english,
        network: Network,
        provider: ProviderConfig,
        bip39Passphrase: String = "",
        iterations: Int = EncryptedKeyManager.defaultIterations,
        accountIndex: UInt32 = 0,
        utxoStore: UTxOStore? = nil,
        gapLimit: UInt32 = 20,
        handleResolver: (any HandleResolver)? = nil
    ) async throws -> (wallet: Wallet, phrase: String, blob: EncryptedBlob) {
        let (km, phrase) = try await EncryptedKeyManager.generate(
            passphrase: passphrase,
            wordCount: wordCount,
            language: language,
            bip39Passphrase: bip39Passphrase,
            iterations: iterations
        )
        let blob = try await km.encryptedBlob(passphrase: passphrase)
        let wallet = try await Self.mnemonic(
            phrase: phrase,
            network: network,
            provider: provider,
            passphrase: bip39Passphrase,
            accountIndex: accountIndex,
            utxoStore: utxoStore,
            gapLimit: gapLimit,
            handleResolver: handleResolver
        )
        return (wallet, phrase, blob)
    }

    /// Generate fresh `.skey` files on disk, then wrap them in a
    /// ``Wallet/textEnvelope(_:)``. The returned URLs are the user's backup — they must
    /// not lose them.
    public static func generateTextEnvelope(
        writeTo directory: URL,
        network: Network,
        provider: ProviderConfig,
        accountIndex: UInt32 = 0,
        overwrite: Bool = false
    ) async throws -> (wallet: Wallet, paymentSkeyURL: URL, stakeSkeyURL: URL) {
        let generated = try await TextEnvelopeWallet.generate(
            writeTo: directory,
            network: network,
            provider: provider,
            accountIndex: accountIndex,
            overwrite: overwrite
        )
        return (.textEnvelope(generated.wallet), generated.paymentSkeyURL, generated.stakeSkeyURL)
    }
}

