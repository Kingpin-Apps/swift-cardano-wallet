import Foundation
#if os(Linux)
import Crypto
#else
import CryptoKit
import Security
#endif

/// Generic passphrase-based sealing of arbitrary secret bytes into an ``EncryptedBlob``.
///
/// Same construction as ``EncryptedKeyManager`` — PBKDF2-HMAC-SHA512 key derivation into
/// AES-256-GCM — but over caller-supplied `Data` with a caller-chosen ``EncryptedBlob/innerKind``.
/// Use it to persist **non-mnemonic** secrets (CLI `.skey` payloads, multisig scripts, hardware
/// key files) through any ``KeyStore`` with exactly the same at-rest protection the mnemonic path
/// gets — one audited crypto path, one storage abstraction.
///
/// ```swift
/// let blob = try SecretBox.seal(secretBytes, passphrase: pw, innerKind: "cli-textenvelope-v1")
/// try await keyStore.save(blob, id: "acct-…")
/// // later
/// let bytes = try SecretBox.open(blob, passphrase: pw, expecting: "cli-textenvelope-v1")
/// ```
///
/// The mnemonic-specific ``EncryptedKeyManager`` remains the codec for BIP-39 blobs
/// (`innerKind == "mnemonic-bip39"`); `SecretBox` deliberately does not interpret the plaintext,
/// so the caller owns the inner encoding.
public enum SecretBox {

    /// Lowest PBKDF2 iteration count accepted on ``open(_:passphrase:expecting:)`` — mirrors
    /// ``EncryptedKeyManager``'s floor so a tampered blob with a trivial work factor is rejected.
    public static let minIterations: Int = 100_000

    /// Encrypt `plaintext` under `passphrase`, returning a storable ``EncryptedBlob`` tagged with
    /// `innerKind`. The `passphrase` must be non-empty; `iterations` must be at least
    /// ``minIterations``.
    public static func seal(
        _ plaintext: Data,
        passphrase: String,
        innerKind: String,
        iterations: Int = EncryptedKeyManager.defaultIterations
    ) throws -> EncryptedBlob {
        guard !passphrase.isEmpty else { throw WalletError.invalidPassphrase }
        guard iterations >= minIterations else {
            throw WalletError.keystore("PBKDF2 iterations \(iterations) below minimum \(minIterations)")
        }

        let salt = randomBytes(EncryptedKeyManager.saltLength)
        var passphraseBytes = EncryptedKeyManager.normalizedPassphraseBytes(passphrase)
        var derivedKey = PBKDF2.deriveKeySHA512(
            password: passphraseBytes,
            salt: salt,
            iterations: iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        passphraseBytes.zeroize()
        defer { derivedKey.zeroize() }

        let symKey = SymmetricKey(data: derivedKey)
        let nonceData = randomBytes(EncryptedKeyManager.nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)

        return EncryptedBlob(
            version: EncryptedBlob.currentVersion,
            iterations: iterations,
            saltBase64: salt.base64EncodedString(),
            nonceBase64: nonceData.base64EncodedString(),
            ciphertextBase64: sealed.ciphertext.base64EncodedString(),
            tagBase64: sealed.tag.base64EncodedString(),
            innerKind: innerKind
        )
    }

    /// Decrypt an ``EncryptedBlob`` produced by ``seal(_:passphrase:innerKind:iterations:)``.
    ///
    /// - Parameter innerKind: when non-nil, the blob's `innerKind` must match or the call throws —
    ///   guards against feeding a mnemonic blob (or an unrelated secret) to the wrong decoder.
    /// - Throws: ``WalletError/invalidPassphrase`` on a wrong passphrase or a tampered ciphertext
    ///   (AES-GCM authentication failure); ``WalletError/keystore(_:)`` on malformed/unsupported
    ///   blobs.
    public static func open(
        _ blob: EncryptedBlob,
        passphrase: String,
        expecting innerKind: String? = nil
    ) throws -> Data {
        guard !passphrase.isEmpty else { throw WalletError.invalidPassphrase }
        guard blob.kdf == EncryptedBlob.kdfPbkdf2SHA512 else {
            throw WalletError.keystore("Unsupported KDF '\(blob.kdf)'")
        }
        guard blob.cipher == EncryptedBlob.cipherAESGCM else {
            throw WalletError.keystore("Unsupported cipher '\(blob.cipher)'")
        }
        if let innerKind, blob.innerKind != innerKind {
            throw WalletError.keystore(
                "Unexpected innerKind '\(blob.innerKind)' (expected '\(innerKind)')"
            )
        }
        guard blob.iterations >= minIterations else {
            throw WalletError.keystore("Blob iterations \(blob.iterations) below minimum \(minIterations)")
        }
        guard
            let salt = Data(base64Encoded: blob.saltBase64),
            let nonceData = Data(base64Encoded: blob.nonceBase64),
            let ciphertext = Data(base64Encoded: blob.ciphertextBase64),
            let tag = Data(base64Encoded: blob.tagBase64)
        else {
            throw WalletError.keystore("Blob contains malformed base64 fields")
        }

        var passphraseBytes = EncryptedKeyManager.normalizedPassphraseBytes(passphrase)
        var derivedKey = PBKDF2.deriveKeySHA512(
            password: passphraseBytes,
            salt: salt,
            iterations: blob.iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        passphraseBytes.zeroize()
        defer { derivedKey.zeroize() }

        let symKey = SymmetricKey(data: derivedKey)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed, using: symKey)
        } catch {
            throw WalletError.invalidPassphrase
        }
    }

    // MARK: - Internals

    private static func randomBytes(_ length: Int) -> Data {
        #if os(Linux)
        var rng = SystemRandomNumberGenerator()
        return Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        #else
        var bytes = Data(count: length)
        let result = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, length, base)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return bytes
        #endif
    }
}
