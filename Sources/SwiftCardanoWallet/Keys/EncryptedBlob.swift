import Foundation

/// Versioned, self-describing serialization of an encrypted ``KeyManager`` payload.
///
/// All bytes are stored as base64 strings so the blob is JSON-friendly. The format is intentionally
/// simple — a single AES-256-GCM ciphertext over a PBKDF2-SHA512-derived key, with iteration
/// count and KDF/cipher names embedded so we can rotate parameters without breaking old blobs.
public struct EncryptedBlob: Codable, Sendable, Equatable {

    /// Latest format version this package emits when calling
    /// ``EncryptedKeyManager/encryptedBlob(passphrase:)``.
    ///
    /// **Version history:**
    /// - **1**: plaintext is `<mnemonic>\n<bip39Passphrase>` (UTF-8). Still readable for
    ///   migration; not produced by new encrypt calls.
    /// - **2** *(current)*: plaintext is a CBOR map keyed by short strings — currently
    ///   `{"m": <mnemonic>, "p": <bip39_passphrase>}` — so future fields can be added
    ///   without ambiguity, and a passphrase containing a newline can't corrupt the parse.
    public static let currentVersion: Int = 2

    /// Smallest version this package can still decrypt. Bumped when an old format is
    /// retired (we have no plans to drop v1 in v0.x).
    public static let minSupportedVersion: Int = 1

    public static let kdfPbkdf2SHA512: String = "pbkdf2-sha512"
    public static let cipherAESGCM: String = "aes-256-gcm"

    public var version: Int
    public var kdf: String
    public var iterations: Int
    public var cipher: String
    public var saltBase64: String
    public var nonceBase64: String      // 12-byte AES-GCM nonce / IV
    public var ciphertextBase64: String
    public var tagBase64: String        // 16-byte AES-GCM tag
    /// Tag describing what plaintext is inside, e.g. `"mnemonic"`. Drives reconstruction.
    public var innerKind: String

    public init(
        version: Int = EncryptedBlob.currentVersion,
        kdf: String = EncryptedBlob.kdfPbkdf2SHA512,
        iterations: Int,
        cipher: String = EncryptedBlob.cipherAESGCM,
        saltBase64: String,
        nonceBase64: String,
        ciphertextBase64: String,
        tagBase64: String,
        innerKind: String
    ) {
        self.version = version
        self.kdf = kdf
        self.iterations = iterations
        self.cipher = cipher
        self.saltBase64 = saltBase64
        self.nonceBase64 = nonceBase64
        self.ciphertextBase64 = ciphertextBase64
        self.tagBase64 = tagBase64
        self.innerKind = innerKind
    }

    public func toJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func fromJSONData(_ data: Data) throws -> EncryptedBlob {
        try JSONDecoder().decode(EncryptedBlob.self, from: data)
    }
}
