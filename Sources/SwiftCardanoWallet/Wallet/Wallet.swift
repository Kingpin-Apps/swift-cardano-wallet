import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoUtils

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

    /// Hardware wallet driven through `cardano-hw-cli`. macOS / Linux only.
    case hardware(HardwareWallet)

    // MARK: - Common reads

    /// The kind of wallet this is. Cheap; no I/O.
    public var kind: WalletKind {
        switch self {
        case .mnemonic(let w): return w.kind
        case .textEnvelope(let w): return w.kind
        case .watchOnly(let w): return w.kind
        case .multisig(let w): return w.kind
        case .hardware(let w): return w.kind
        }
    }

    /// The wallet's Cardano network (mainnet / preprod / preview).
    public var network: Network {
        switch self {
        case .mnemonic(let w): return w.network
        case .textEnvelope(let w): return w.network
        case .watchOnly(let w): return w.network
        case .multisig(let w): return w.policy.network
        case .hardware(let w): return w.network
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
        case .hardware(let w): return w.address
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
        case .hardware(let w): return try await w.utxos()
        }
    }

    /// Aggregate balance — lovelace, multi-asset, rewards (mnemonic only), UTxO count.
    public func balance() async throws -> WalletBalance {
        switch self {
        case .mnemonic(let w): return try await w.balance()
        case .textEnvelope(let w): return try await w.balance()
        case .watchOnly(let w): return try await w.balance()
        case .multisig(let w): return try await w.balance()
        case .hardware(let w): return try await w.balance()
        }
    }

    /// Underlying chain context. Useful for escape-hatch ``TxBuilder`` usage.
    public func chainContext() -> any ChainContext {
        switch self {
        case .mnemonic(let w): return w.chainContextHandle()
        case .textEnvelope(let w): return w.chainContextHandle()
        case .watchOnly(let w): return w.chainContextHandle()
        case .multisig(let w): return w.chainContextHandle()
        case .hardware(let w): return w.chainContextHandle()
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

    /// The wrapped ``HardwareWallet`` or `nil`.
    public var hardwareWallet: HardwareWallet? {
        if case .hardware(let w) = self { return w }
        return nil
    }

    /// `true` if this wallet kind can produce signatures locally. Watch-only wallets
    /// return `false`; everything else returns `true` (multisig / hardware sign through
    /// their own flows but `canSign` is `true` for the local participant).
    public var canSign: Bool {
        switch self {
        case .watchOnly: return false
        case .mnemonic, .textEnvelope, .multisig, .hardware: return true
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
        case .hardware:
            throw WalletError.unsupportedOperation(
                "Hardware wallet sends need device interaction. Use `wallet.hardwareWallet?.prepareSend(...)` then `signWithDevice()` or `attachWitnesses(fromFiles:)`."
            )
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
        case .textEnvelope, .multisig, .hardware:
            throw WalletError.unsupportedOperation(
                "sendTo(handle:) is only wired up for mnemonic wallets in v0.1.0. Resolve the handle yourself via DefaultHandleResolver and pass the resulting Address to the concrete wallet's prepareSend."
            )
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
}

