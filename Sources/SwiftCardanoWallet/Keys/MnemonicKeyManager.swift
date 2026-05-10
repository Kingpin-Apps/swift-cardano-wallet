import Foundation
import SwiftCardanoCore

/// HD key manager backed by a BIP-39 mnemonic + BIP-32-Ed25519 (CIP-3) derivation.
///
/// Derives keys on demand at any ``DerivationPath``. Caches derived extended signing keys
/// inside the actor so repeat lookups don't re-run PBKDF2 / HMAC-SHA512.
public actor MnemonicKeyManager: KeyManager {
    public nonisolated let kind: WalletKind = .mnemonic
    public nonisolated let canSign: Bool = true

    private let hdWallet: HDWallet
    private var paymentSkeyCache: [DerivationPath: PaymentExtendedSigningKey] = [:]
    private var stakeSkeyCache: [DerivationPath: StakeExtendedSigningKey] = [:]

    /// Construct from a mnemonic phrase (12 / 15 / 18 / 21 / 24 words).
    public init(mnemonic: String, passphrase: String = "") throws {
        do {
            self.hdWallet = try HDWallet.fromMnemonic(mnemonic: mnemonic, passphrase: passphrase)
        } catch {
            throw WalletError.invalidMnemonic("\(error)")
        }
    }

    /// Construct from raw entropy (16 / 20 / 24 / 28 / 32 bytes).
    public init(entropy: Data, passphrase: String = "") throws {
        do {
            self.hdWallet = try HDWallet.fromEntropy(
                entropy: entropy.map { String(format: "%02x", $0) }.joined(),
                passphrase: passphrase
            )
        } catch {
            throw WalletError.invalidMnemonic("\(error)")
        }
    }

    // MARK: - KeyManager

    public func paymentVerificationKey(at path: DerivationPath) throws -> PaymentVerificationKey {
        let skey = try cachedPaymentSkey(at: path)
        let extVKey: PaymentExtendedVerificationKey = try skey.toVerificationKey()
        return try extVKey.toNonExtended()
    }

    public func stakeVerificationKey(at path: DerivationPath) throws -> StakeVerificationKey {
        let skey = try cachedStakeSkey(at: path)
        let extVKey: StakeExtendedVerificationKey = try skey.toVerificationKey()
        return try extVKey.toNonExtended()
    }

    public func paymentSigningKeyType(at path: DerivationPath) throws -> SigningKeyType {
        .extendedSigningKey(try cachedPaymentSkey(at: path))
    }

    public func stakeSigningKeyType(at path: DerivationPath) throws -> SigningKeyType {
        .extendedSigningKey(try cachedStakeSkey(at: path))
    }

    // MARK: - Internals

    private func cachedPaymentSkey(at path: DerivationPath) throws -> PaymentExtendedSigningKey {
        if let cached = paymentSkeyCache[path] { return cached }
        let derived: PaymentExtendedSigningKey
        do {
            let child = try hdWallet.derive(fromPath: path.description)
            let payload = child.xPrivateKey + child.publicKey + child.chainCode
            derived = PaymentExtendedSigningKey(
                payload: payload,
                type: PaymentExtendedSigningKey.TYPE,
                description: PaymentExtendedSigningKey.DESCRIPTION
            )
        } catch let error as WalletError {
            throw error
        } catch {
            throw WalletError.derivationFailed("\(path): \(error)")
        }
        paymentSkeyCache[path] = derived
        return derived
    }

    private func cachedStakeSkey(at path: DerivationPath) throws -> StakeExtendedSigningKey {
        if let cached = stakeSkeyCache[path] { return cached }
        let derived: StakeExtendedSigningKey
        do {
            let child = try hdWallet.derive(fromPath: path.description)
            let payload = child.xPrivateKey + child.publicKey + child.chainCode
            derived = StakeExtendedSigningKey(
                payload: payload,
                type: StakeExtendedSigningKey.TYPE,
                description: StakeExtendedSigningKey.DESCRIPTION
            )
        } catch let error as WalletError {
            throw error
        } catch {
            throw WalletError.derivationFailed("\(path): \(error)")
        }
        stakeSkeyCache[path] = derived
        return derived
    }
}
