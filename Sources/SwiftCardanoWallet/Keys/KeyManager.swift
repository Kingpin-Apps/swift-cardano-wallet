import Foundation
import SwiftCardanoCore

/// Abstract source of payment / stake keys for a wallet.
///
/// Concrete impls in v0.1.0:
/// - ``MnemonicKeyManager`` (PR 2)
/// - ``TextEnvelopeKeyManager`` (PR 5) — `cardano-cli` `.skey` files
/// - ``WatchOnlyKeyManager`` (PR 5) — public keys only
/// - ``EncryptedKeyManager`` (PR 5) — passphrase-encrypted wrapper around another KM
/// - `MultisigKeyManager` (PR 11)
/// - `HardwareKeyManager` (PR 13)
///
/// Returns ``SwiftCardanoCore/SigningKeyType`` from signing methods so both extended (HD-style)
/// and non-extended (vanilla `cardano-cli`) keys are covered uniformly.
public protocol KeyManager: Sendable {
    var kind: WalletKind { get }

    /// Whether this manager can produce signing material. Watch-only managers return `false`.
    var canSign: Bool { get }

    func paymentVerificationKey(at path: DerivationPath) async throws -> PaymentVerificationKey
    func stakeVerificationKey(at path: DerivationPath) async throws -> StakeVerificationKey

    /// The wallet's DRep (CIP-0105) verification key at a `.drep`-role path. HD managers derive it
    /// like any other key; managers without HD material inherit the throwing default below.
    func drepVerificationKey(at path: DerivationPath) async throws -> DRepVerificationKey

    /// Returns a ``SwiftCardanoCore/SigningKeyType`` that can sign a transaction body hash and
    /// produce a witness-compatible verification key. Throws ``WalletError/watchOnly`` on
    /// watch-only managers.
    func paymentSigningKeyType(at path: DerivationPath) async throws -> SigningKeyType
    func stakeSigningKeyType(at path: DerivationPath) async throws -> SigningKeyType

    /// DRep-key signing material at a `.drep`-role path. Default throws; HD managers override.
    func drepSigningKeyType(at path: DerivationPath) async throws -> SigningKeyType
}

extension KeyManager {
    /// Default: no DRep-key support. HD managers (mnemonic / encrypted) override these.
    public func drepVerificationKey(at path: DerivationPath) async throws -> DRepVerificationKey {
        throw WalletError.unsupportedOperation("\(kind) wallets do not support DRep keys")
    }

    public func drepSigningKeyType(at path: DerivationPath) async throws -> SigningKeyType {
        throw WalletError.unsupportedOperation("\(kind) wallets do not support DRep keys")
    }

    /// Convenience: fetch as a typed extended signing key. Throws ``WalletError/unsupportedOperation``
    /// if the manager produces non-extended (vanilla `cardano-cli`) keys.
    public func paymentSigningKey(at path: DerivationPath) async throws -> PaymentExtendedSigningKey {
        let type = try await paymentSigningKeyType(at: path)
        guard case let .extendedSigningKey(key) = type, let typed = key as? PaymentExtendedSigningKey else {
            throw WalletError.unsupportedOperation(
                "paymentSigningKey(at:) requires an extended Ed25519-BIP32 key; \(kind) returned a non-extended key"
            )
        }
        return typed
    }

    /// Convenience: fetch as a typed extended signing key. Throws if non-extended.
    public func stakeSigningKey(at path: DerivationPath) async throws -> StakeExtendedSigningKey {
        let type = try await stakeSigningKeyType(at: path)
        guard case let .extendedSigningKey(key) = type, let typed = key as? StakeExtendedSigningKey else {
            throw WalletError.unsupportedOperation(
                "stakeSigningKey(at:) requires an extended Ed25519-BIP32 key; \(kind) returned a non-extended key"
            )
        }
        return typed
    }
}
