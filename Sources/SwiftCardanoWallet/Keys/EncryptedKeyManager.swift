import Foundation
import CryptoKit
import Security
import SwiftCardanoCore

/// Wraps a ``MnemonicKeyManager`` with passphrase-based encryption.
///
/// Construct one of three ways:
/// - ``init(mnemonic:passphrase:bip39Passphrase:iterations:)`` to encrypt a fresh phrase for export.
/// - ``init(blob:passphrase:)`` to decrypt a saved blob.
/// - ``init(inner:passphrase:iterations:)`` to wrap an existing ``MnemonicKeyManager`` (advanced).
///
/// All KeyManager operations forward to the inner manager (which holds the decrypted mnemonic in
/// memory while the wallet is open). Encryption protects keys **at rest** — call
/// ``encryptedBlob()`` to produce a JSON-serializable ``EncryptedBlob`` that you can persist via
/// any ``KeyStore``.
public actor EncryptedKeyManager: KeyManager {

    public nonisolated let kind: WalletKind = .encrypted
    public nonisolated let canSign: Bool = true

    public static let defaultIterations: Int = 210_000
    public static let saltLength: Int = 16
    public static let nonceLength: Int = 12
    public static let keyLength: Int = 32

    /// Tag stored in ``EncryptedBlob/innerKind`` for blobs whose plaintext is a BIP-39 mnemonic.
    /// Future inner kinds (e.g. CLI key payloads) get their own tags.
    public static let innerKindMnemonic: String = "mnemonic-bip39"

    private let inner: MnemonicKeyManager
    private let mnemonicPlaintext: String      // kept for re-encryption / re-export
    private let bip39PassphrasePlaintext: String
    private let iterations: Int

    /// The decrypted mnemonic phrase. **Sensitive** — holding this in plain memory is the
    /// same security boundary as holding the ``MnemonicKeyManager`` itself. Exposed so
    /// higher-level factories (e.g. ``Wallet/encrypted(blob:passphrase:network:provider:)``)
    /// can reconstruct a ``MnemonicWallet`` after decryption. The actor isolation gates
    /// access; do not log or persist this value.
    public var mnemonic: String { mnemonicPlaintext }

    /// The decrypted BIP-39 passphrase (empty string if none). Same caveats as
    /// ``mnemonic``.
    public var bip39Passphrase: String { bip39PassphrasePlaintext }

    // MARK: - Construction

    /// Create from a fresh mnemonic, ready to encrypt.
    public init(
        mnemonic: String,
        passphrase: String,
        bip39Passphrase: String = "",
        iterations: Int = EncryptedKeyManager.defaultIterations
    ) async throws {
        guard !passphrase.isEmpty else {
            throw WalletError.invalidPassphrase
        }
        self.mnemonicPlaintext = mnemonic
        self.bip39PassphrasePlaintext = bip39Passphrase
        self.iterations = iterations
        self.inner = try MnemonicKeyManager(mnemonic: mnemonic, passphrase: bip39Passphrase)
    }

    /// Create by decrypting a stored blob.
    public init(blob: EncryptedBlob, passphrase: String) async throws {
        guard !passphrase.isEmpty else { throw WalletError.invalidPassphrase }
        guard blob.version == EncryptedBlob.currentVersion else {
            throw WalletError.keystore("Unsupported blob version \(blob.version)")
        }
        guard blob.kdf == EncryptedBlob.kdfPbkdf2SHA512 else {
            throw WalletError.keystore("Unsupported KDF '\(blob.kdf)'")
        }
        guard blob.cipher == EncryptedBlob.cipherAESGCM else {
            throw WalletError.keystore("Unsupported cipher '\(blob.cipher)'")
        }
        guard blob.innerKind == EncryptedKeyManager.innerKindMnemonic else {
            throw WalletError.keystore(
                "Unsupported innerKind '\(blob.innerKind)' (only '\(EncryptedKeyManager.innerKindMnemonic)' is wired up)"
            )
        }
        guard
            let salt = Data(base64Encoded: blob.saltBase64),
            let nonceData = Data(base64Encoded: blob.nonceBase64),
            let ciphertext = Data(base64Encoded: blob.ciphertextBase64),
            let tag = Data(base64Encoded: blob.tagBase64)
        else {
            throw WalletError.keystore("Blob contains malformed base64 fields")
        }

        let derivedKey = PBKDF2.deriveKeySHA512(
            password: Data(passphrase.utf8),
            salt: salt,
            iterations: blob.iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        let symKey = SymmetricKey(data: derivedKey)

        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(sealed, using: symKey)
        } catch {
            throw WalletError.invalidPassphrase
        }

        // The plaintext is `<mnemonic>\n<bip39Passphrase>` (passphrase may be empty).
        let raw = String(decoding: plaintext, as: UTF8.self)
        let parts = raw.components(separatedBy: "\n")
        guard let phrase = parts.first else {
            throw WalletError.keystore("Decrypted blob is malformed")
        }
        let bip39 = parts.count > 1 ? parts.dropFirst().joined(separator: "\n") : ""

        self.mnemonicPlaintext = phrase
        self.bip39PassphrasePlaintext = bip39
        self.iterations = blob.iterations
        self.inner = try MnemonicKeyManager(mnemonic: phrase, passphrase: bip39)
    }

    // MARK: - Export

    /// Re-encrypt the wrapped mnemonic with the given passphrase, producing a storable blob.
    public func encryptedBlob(passphrase: String) throws -> EncryptedBlob {
        guard !passphrase.isEmpty else { throw WalletError.invalidPassphrase }

        let salt = Self.randomBytes(EncryptedKeyManager.saltLength)
        let derivedKey = PBKDF2.deriveKeySHA512(
            password: Data(passphrase.utf8),
            salt: salt,
            iterations: iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        let symKey = SymmetricKey(data: derivedKey)
        let nonceData = Self.randomBytes(EncryptedKeyManager.nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        var plaintext = Data(mnemonicPlaintext.utf8)
        plaintext.append(0x0a)  // \n
        plaintext.append(Data(bip39PassphrasePlaintext.utf8))

        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        return EncryptedBlob(
            iterations: iterations,
            saltBase64: salt.base64EncodedString(),
            nonceBase64: nonceData.base64EncodedString(),
            ciphertextBase64: sealed.ciphertext.base64EncodedString(),
            tagBase64: sealed.tag.base64EncodedString(),
            innerKind: EncryptedKeyManager.innerKindMnemonic
        )
    }

    // MARK: - KeyManager forwarding

    public func paymentVerificationKey(at path: DerivationPath) async throws -> PaymentVerificationKey {
        try await inner.paymentVerificationKey(at: path)
    }

    public func stakeVerificationKey(at path: DerivationPath) async throws -> StakeVerificationKey {
        try await inner.stakeVerificationKey(at: path)
    }

    public func paymentSigningKeyType(at path: DerivationPath) async throws -> SigningKeyType {
        try await inner.paymentSigningKeyType(at: path)
    }

    public func stakeSigningKeyType(at path: DerivationPath) async throws -> SigningKeyType {
        try await inner.stakeSigningKeyType(at: path)
    }

    // MARK: - Internals

    private static func randomBytes(_ length: Int) -> Data {
        var bytes = Data(count: length)
        let result = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, length, base)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return bytes
    }
}
