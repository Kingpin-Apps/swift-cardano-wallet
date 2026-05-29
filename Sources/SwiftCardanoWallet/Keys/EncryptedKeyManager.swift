import Foundation
import CryptoKit
import Security
import OrderedCollections
import SwiftCardanoCore
import SwiftMnemonic

/// Minimum PBKDF2 iteration count we will accept on decrypt. Roughly half the
/// recommended default — gives us headroom to lower the default in a future release
/// without bricking blobs already in the wild, while still rejecting a tampered blob
/// whose `iterations` field was rewritten to something trivially crackable.
private let minDecryptIterations: Int = 100_000

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
        guard iterations >= minDecryptIterations else {
            throw WalletError.keystore(
                "PBKDF2 iterations \(iterations) below minimum \(minDecryptIterations)"
            )
        }
        self.mnemonicPlaintext = mnemonic
        self.bip39PassphrasePlaintext = bip39Passphrase
        self.iterations = iterations
        self.inner = try MnemonicKeyManager(mnemonic: mnemonic, passphrase: bip39Passphrase)
    }

    /// Create by decrypting a stored blob. Accepts both format ``EncryptedBlob/currentVersion``
    /// and the legacy v1 (`\n`-delimited plaintext).
    public init(blob: EncryptedBlob, passphrase: String) async throws {
        guard !passphrase.isEmpty else { throw WalletError.invalidPassphrase }
        guard blob.version >= EncryptedBlob.minSupportedVersion,
              blob.version <= EncryptedBlob.currentVersion else {
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
        // Reject blobs with implausibly low iteration counts even if the cipher would
        // happily decrypt — a tampered blob with iterations=1 is a brute-force tee-up.
        guard blob.iterations >= minDecryptIterations else {
            throw WalletError.keystore(
                "Blob iterations \(blob.iterations) below minimum \(minDecryptIterations)"
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

        var passphraseBytes = Self.normalizedPassphraseBytes(passphrase)
        var derivedKey = PBKDF2.deriveKeySHA512(
            password: passphraseBytes,
            salt: salt,
            iterations: blob.iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        passphraseBytes.zeroize()
        defer { derivedKey.zeroize() }
        let symKey = SymmetricKey(data: derivedKey)

        var plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(sealed, using: symKey)
        } catch {
            throw WalletError.invalidPassphrase
        }
        defer { plaintext.zeroize() }

        let phrase: String
        let bip39: String
        switch blob.version {
        case 1:
            (phrase, bip39) = try Self.decodePlaintextV1(plaintext)
        default:
            (phrase, bip39) = try Self.decodePlaintextV2(plaintext)
        }

        self.mnemonicPlaintext = phrase
        self.bip39PassphrasePlaintext = bip39
        self.iterations = blob.iterations
        self.inner = try MnemonicKeyManager(mnemonic: phrase, passphrase: bip39)
    }

    // MARK: - Export

    /// Re-encrypt the wrapped mnemonic with the given passphrase, producing a storable
    /// blob in the current format (``EncryptedBlob/currentVersion``).
    public func encryptedBlob(passphrase: String) throws -> EncryptedBlob {
        guard !passphrase.isEmpty else { throw WalletError.invalidPassphrase }

        let salt = Self.randomBytes(EncryptedKeyManager.saltLength)
        var passphraseBytes = Self.normalizedPassphraseBytes(passphrase)
        var derivedKey = PBKDF2.deriveKeySHA512(
            password: passphraseBytes,
            salt: salt,
            iterations: iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        passphraseBytes.zeroize()
        defer { derivedKey.zeroize() }
        let symKey = SymmetricKey(data: derivedKey)
        let nonceData = Self.randomBytes(EncryptedKeyManager.nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        var plaintext = try Self.encodePlaintextV2(
            mnemonic: mnemonicPlaintext,
            bip39Passphrase: bip39PassphrasePlaintext
        )
        defer { plaintext.zeroize() }

        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        return EncryptedBlob(
            version: EncryptedBlob.currentVersion,
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

    /// NFKC-normalize the passphrase before feeding it to PBKDF2. Matches BIP-39's own
    /// normalization rule for the wallet passphrase: a user who typed `café` with a
    /// composed `é` on one device must derive the same key on a device that decomposes
    /// the accent. Applied symmetrically in encrypt + decrypt.
    static func normalizedPassphraseBytes(_ passphrase: String) -> Data {
        Data(passphrase.precomposedStringWithCompatibilityMapping.utf8)
    }

    // MARK: - Plaintext format

    // Short keys keep the encrypted payload compact (extra bytes don't hurt security but
    // bloat every saved blob). Treat as wire constants — never rename.
    private static let v2KeyMnemonic: String = "m"
    private static let v2KeyPassphrase: String = "p"

    /// v2 plaintext: CBOR map `{"m": <mnemonic>, "p": <bip39_passphrase>}`. Map shape
    /// means a future field can be added without ambiguity, and an embedded newline in
    /// the passphrase can't break the parse the way the v1 `\n`-delimited format did.
    static func encodePlaintextV2(mnemonic: String, bip39Passphrase: String) throws -> Data {
        var map: OrderedDictionary<Primitive, Primitive> = [:]
        map[.string(v2KeyMnemonic)] = .string(mnemonic)
        map[.string(v2KeyPassphrase)] = .string(bip39Passphrase)
        do {
            return try Primitive.orderedDict(map).toCBORData()
        } catch {
            throw WalletError.keystore("Failed to encode v2 plaintext: \(error)")
        }
    }

    static func decodePlaintextV2(_ plaintext: Data) throws -> (mnemonic: String, bip39Passphrase: String) {
        let primitive: Primitive
        do {
            primitive = try Primitive.fromCBOR(data: plaintext)
        } catch {
            throw WalletError.keystore("Decrypted v2 plaintext is not valid CBOR: \(error)")
        }
        // Accept either ordered or unordered map — the CBOR codec can round-trip into
        // either depending on canonicalization choices.
        let entries: [(Primitive, Primitive)]
        switch primitive {
        case .orderedDict(let m): entries = Array(m)
        case .dict(let m): entries = Array(m)
        case .indefiniteDictionary(let m): entries = Array(m)
        case .frozenDict(let m): entries = Array(m)
        default:
            throw WalletError.keystore("Decrypted v2 plaintext is not a map")
        }
        var mnemonic: String?
        var bip39: String = ""
        for (key, value) in entries {
            guard case .string(let k) = key, case .string(let v) = value else { continue }
            switch k {
            case v2KeyMnemonic:    mnemonic = v
            case v2KeyPassphrase:  bip39 = v
            default: break  // forward-compat: ignore unknown fields
            }
        }
        guard let phrase = mnemonic else {
            throw WalletError.keystore("v2 plaintext missing required field '\(v2KeyMnemonic)'")
        }
        return (phrase, bip39)
    }

    /// Legacy v1 plaintext: `<mnemonic>\n<bip39_passphrase>` (UTF-8, may be empty
    /// passphrase). Kept so blobs written by older builds still open.
    static func decodePlaintextV1(_ plaintext: Data) throws -> (mnemonic: String, bip39Passphrase: String) {
        let raw = String(decoding: plaintext, as: UTF8.self)
        let parts = raw.components(separatedBy: "\n")
        guard let phrase = parts.first else {
            throw WalletError.keystore("v1 plaintext is empty")
        }
        let bip39 = parts.count > 1 ? parts.dropFirst().joined(separator: "\n") : ""
        return (phrase, bip39)
    }

    // MARK: - Generation

    /// Generate a fresh BIP-39 phrase, wrap it in an encrypted key manager, and return
    /// both. The caller typically immediately calls ``encryptedBlob(passphrase:)`` on
    /// the returned manager to persist via a ``KeyStore``.
    ///
    /// ```swift
    /// let generated = try await EncryptedKeyManager.generate(
    ///     passphrase: "correct horse battery staple"
    /// )
    /// userBackupSheet.show(phrase: generated.phrase)
    /// let blob = try await generated.manager.encryptedBlob(passphrase: "correct horse battery staple")
    /// try await keyStore.save(blob, id: "primary")
    /// ```
    ///
    /// - Parameters:
    ///   - passphrase: protects the encrypted blob at rest. Must be non-empty.
    ///   - wordCount: 12 / 15 / 18 / 21 / 24. Defaults to 24.
    ///   - language: BIP-39 wordlist language. Defaults to
    ///     ``SwiftMnemonic/Language/english``. **Only English is currently supported
    ///     end-to-end** — see ``MnemonicWallet/generate(wordCount:language:network:provider:passphrase:accountIndex:utxoStore:gapLimit:handleResolver:)``
    ///     for the upstream limitation.
    ///   - bip39Passphrase: optional BIP-39 25th-word passphrase. Empty by default.
    ///   - iterations: PBKDF2-SHA512 iteration count. Defaults to
    ///     ``defaultIterations``; must be at least 100,000.
    public static func generate(
        passphrase: String,
        wordCount: Int = 24,
        language: SwiftMnemonic.Language = .english,
        bip39Passphrase: String = "",
        iterations: Int = EncryptedKeyManager.defaultIterations
    ) async throws -> (manager: EncryptedKeyManager, phrase: String) {
        guard let wc = SwiftMnemonic.WordCount(rawValue: wordCount) else {
            throw WalletError.configurationMissing(
                "wordCount must be 12, 15, 18, 21, or 24; got \(wordCount)."
            )
        }
        guard language == .english else {
            throw WalletError.unsupportedOperation(
                "Mnemonic generation in language \(language) is not yet supported end-to-end. Only .english works today."
            )
        }
        let words: [String]
        do {
            words = try HDWallet.generateMnemonic(language: language, wordCount: wc)
        } catch {
            throw WalletError.derivationFailed("mnemonic generation failed: \(error)")
        }
        let phrase = words.joined(separator: " ")
        let km = try await EncryptedKeyManager(
            mnemonic: phrase,
            passphrase: passphrase,
            bip39Passphrase: bip39Passphrase,
            iterations: iterations
        )
        return (km, phrase)
    }
}
