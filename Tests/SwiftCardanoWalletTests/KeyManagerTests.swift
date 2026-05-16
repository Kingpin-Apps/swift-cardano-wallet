import Testing
import Foundation
import CryptoKit
import SwiftCardanoCore
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

// MARK: - Helpers

private func hexEncode(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Build a TextEnvelope JSON file containing the given payload, returning the URL.
private func writeTextEnvelope(
    type: String,
    description: String,
    payload: Data,
    in dir: URL
) throws -> URL {
    // CBOR major type 2 (byte string) header: 0x58 <len> for lengths in 24..255.
    var cbor = Data()
    cbor.append(0x58)
    cbor.append(UInt8(payload.count))
    cbor.append(payload)
    let json: [String: String] = [
        "type": type,
        "description": description,
        "cborHex": hexEncode(cbor),
    ]
    let url = dir.appendingPathComponent("\(UUID().uuidString).skey")
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    try data.write(to: url)
    return url
}

private func makeTempDir(_ label: String = "wallet-test") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - TextEnvelopeKeyManager

@Suite("TextEnvelopeKeyManager")
struct TextEnvelopeKeyManagerTests {

    @Test func loadingExtendedKeysProducesSameAddressAsMnemonic() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let paymentExtSkey = try await mnemonicKM.paymentSigningKey(at: .payment(account: 0, index: 0))
        let stakeExtSkey = try await mnemonicKM.stakeSigningKey(at: .stake(account: 0, index: 0))

        let dir = try makeTempDir()
        let paymentURL = try writeTextEnvelope(
            type: PaymentExtendedSigningKey.TYPE,
            description: PaymentExtendedSigningKey.DESCRIPTION,
            payload: paymentExtSkey.payload,
            in: dir
        )
        let stakeURL = try writeTextEnvelope(
            type: StakeExtendedSigningKey.TYPE,
            description: StakeExtendedSigningKey.DESCRIPTION,
            payload: stakeExtSkey.payload,
            in: dir
        )

        let teKM = try TextEnvelopeKeyManager(
            paymentKeyFile: paymentURL,
            stakeKeyFile: stakeURL
        )

        // Same VKs as the mnemonic-based KM.
        let vkA = try await mnemonicKM.paymentVerificationKey(at: .payment())
        let vkB = try await teKM.paymentVerificationKey(at: .payment())
        #expect(vkA.payload == vkB.payload)

        // Same address built from the loaded keys.
        let acct = Account(network: .mainnet)
        let addrA = try await acct.address(with: mnemonicKM)
        let addrB = try await acct.address(with: teKM)
        #expect(addrA == addrB)
    }

    @Test func loadingNonExtendedKeysReturnsNonExtendedSigningKeyType() async throws {
        // Synthesize a non-extended PaymentSigningKey by taking the first 32 bytes of an
        // extended key — not cryptographically correct but exercises the code path.
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let extSkey = try await mnemonicKM.paymentSigningKey(at: .payment())
        let payload32 = extSkey.payload.prefix(32)

        let dir = try makeTempDir()
        let url = try writeTextEnvelope(
            type: PaymentSigningKey.TYPE,
            description: PaymentSigningKey.DESCRIPTION,
            payload: Data(payload32),
            in: dir
        )

        let teKM = try TextEnvelopeKeyManager(paymentKeyFile: url)
        let skeyType = try await teKM.paymentSigningKeyType(at: .payment())
        guard case .signingKey = skeyType else {
            Issue.record("Expected .signingKey case, got \(skeyType)")
            return
        }
    }

    @Test func wrongTypeTagThrows() throws {
        let dir = try makeTempDir()
        let url = try writeTextEnvelope(
            type: "NotARealKeyType",
            description: "x",
            payload: Data(repeating: 0, count: 32),
            in: dir
        )
        #expect(throws: WalletError.self) {
            _ = try TextEnvelopeKeyManager(paymentKeyFile: url)
        }
    }

    @Test func stakeRequestWithoutStakeFileThrows() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let paymentExtSkey = try await mnemonicKM.paymentSigningKey(at: .payment())

        let dir = try makeTempDir()
        let url = try writeTextEnvelope(
            type: PaymentExtendedSigningKey.TYPE,
            description: PaymentExtendedSigningKey.DESCRIPTION,
            payload: paymentExtSkey.payload,
            in: dir
        )
        let teKM = try TextEnvelopeKeyManager(paymentKeyFile: url)

        do {
            _ = try await teKM.stakeVerificationKey(at: .stake())
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func nonExtendedKeyRejectsTypedExtendedAccessor() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let extSkey = try await mnemonicKM.paymentSigningKey(at: .payment())
        let payload32 = extSkey.payload.prefix(32)

        let dir = try makeTempDir()
        let url = try writeTextEnvelope(
            type: PaymentSigningKey.TYPE,
            description: PaymentSigningKey.DESCRIPTION,
            payload: Data(payload32),
            in: dir
        )
        let teKM = try TextEnvelopeKeyManager(paymentKeyFile: url)

        // The typed extended accessor should refuse non-extended keys.
        do {
            _ = try await teKM.paymentSigningKey(at: .payment())
            Issue.record("Expected unsupportedOperation")
        } catch let error as WalletError {
            switch error {
            case .unsupportedOperation: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }
}

// MARK: - WatchOnlyKeyManager

@Suite("WatchOnlyKeyManager")
struct WatchOnlyKeyManagerTests {

    @Test func canDeriveAddressFromVerificationKeysOnly() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let pVKey = try await mnemonicKM.paymentVerificationKey(at: .payment())
        let sVKey = try await mnemonicKM.stakeVerificationKey(at: .stake())

        let watch = WatchOnlyKeyManager(
            paymentVerificationKey: pVKey,
            stakeVerificationKey: sVKey
        )
        #expect(watch.canSign == false)

        let acct = Account(network: .mainnet)
        let addrM = try await acct.address(with: mnemonicKM)
        let addrW = try await acct.address(with: watch)
        #expect(addrM == addrW)
    }

    @Test func signingThrowsWatchOnly() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let pVKey = try await mnemonicKM.paymentVerificationKey(at: .payment())
        let watch = WatchOnlyKeyManager(paymentVerificationKey: pVKey)

        do {
            _ = try watch.paymentSigningKeyType(at: .payment())
            Issue.record("Expected watchOnly error")
        } catch let error as WalletError {
            #expect(error == .watchOnly)
        }
    }
}

// MARK: - EncryptedKeyManager + FileKeyStore

@Suite("EncryptedKeyManager round-trip")
struct EncryptedKeyManagerTests {

    @Test func encryptThenDecryptYieldsMatchingAddress() async throws {
        let original = try await EncryptedKeyManager(
            mnemonic: testMnemonic,
            passphrase: "correct horse battery staple"
        )
        let acct = Account(network: .mainnet)
        let originalAddr = try await acct.address(with: original)

        let blob = try await original.encryptedBlob(passphrase: "correct horse battery staple")
        let restored = try await EncryptedKeyManager(
            blob: blob,
            passphrase: "correct horse battery staple"
        )
        let restoredAddr = try await acct.address(with: restored)

        #expect(originalAddr == restoredAddr)
    }

    @Test func wrongPassphraseFailsDecryption() async throws {
        let original = try await EncryptedKeyManager(
            mnemonic: testMnemonic,
            passphrase: "right one"
        )
        let blob = try await original.encryptedBlob(passphrase: "right one")

        do {
            _ = try await EncryptedKeyManager(blob: blob, passphrase: "WRONG one")
            Issue.record("Expected invalidPassphrase")
        } catch let error as WalletError {
            #expect(error == .invalidPassphrase)
        }
    }

    @Test func emptyPassphraseRejected() async throws {
        do {
            _ = try await EncryptedKeyManager(
                mnemonic: testMnemonic,
                passphrase: ""
            )
            Issue.record("Expected invalidPassphrase")
        } catch let error as WalletError {
            #expect(error == .invalidPassphrase)
        }
    }

    @Test func bip39PassphraseSurvivesEncryptionRoundTrip() async throws {
        let original = try await EncryptedKeyManager(
            mnemonic: testMnemonic,
            passphrase: "encrypt-pass",
            bip39Passphrase: "TREZOR"
        )
        let blob = try await original.encryptedBlob(passphrase: "encrypt-pass")
        let restored = try await EncryptedKeyManager(
            blob: blob,
            passphrase: "encrypt-pass"
        )

        let acct = Account(network: .mainnet)
        let a = try await acct.address(with: original)
        let b = try await acct.address(with: restored)
        #expect(a == b)

        // And it should differ from a wallet WITHOUT the bip39 passphrase.
        let plain = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let c = try await acct.address(with: plain)
        #expect(a != c)
    }

    @Test func tamperedCiphertextFails() async throws {
        let original = try await EncryptedKeyManager(
            mnemonic: testMnemonic,
            passphrase: "pp"
        )
        var blob = try await original.encryptedBlob(passphrase: "pp")

        // Flip a byte in the ciphertext.
        var ct = Data(base64Encoded: blob.ciphertextBase64)!
        ct[0] ^= 0xff
        blob.ciphertextBase64 = ct.base64EncodedString()

        do {
            _ = try await EncryptedKeyManager(blob: blob, passphrase: "pp")
            Issue.record("Expected invalidPassphrase (AES-GCM auth tag mismatch)")
        } catch let error as WalletError {
            #expect(error == .invalidPassphrase)
        }
    }

    @Test func freshBlobUsesCurrentVersion() async throws {
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")
        #expect(blob.version == EncryptedBlob.currentVersion)
    }

    /// Decrypt path must reject tampered blobs whose `iterations` field was rewritten to
    /// something trivially crackable, even if the cipher would happily authenticate.
    @Test func sub100kIterationsRejectedOnDecrypt() async throws {
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        var blob = try await km.encryptedBlob(passphrase: "pp")
        blob.iterations = 1_000

        do {
            _ = try await EncryptedKeyManager(blob: blob, passphrase: "pp")
            Issue.record("Expected keystore error for low iterations")
        } catch let error as WalletError {
            if case .keystore(let msg) = error {
                #expect(msg.contains("iterations"))
            } else {
                Issue.record("Wrong error variant: \(error)")
            }
        }
    }

    @Test func sub100kIterationsRejectedOnEncrypt() async throws {
        do {
            _ = try await EncryptedKeyManager(
                mnemonic: testMnemonic,
                passphrase: "pp",
                iterations: 1_000
            )
            Issue.record("Expected keystore error for low iterations")
        } catch let error as WalletError {
            if case .keystore = error { /* ok */ } else {
                Issue.record("Wrong error variant: \(error)")
            }
        }
    }

    /// NFKC normalization: a passphrase typed with composed `é` (one code point) must
    /// decrypt a blob encrypted with the decomposed form (`e` + combining acute, two
    /// code points). The raw UTF-8 bytes differ (2 vs 3); both reduce to the same byte
    /// sequence after NFKC. Without normalization the PBKDF2 inputs would differ and
    /// decryption would fail with `.invalidPassphrase`.
    @Test func passphraseNormalizationMatchesAcrossForms() async throws {
        let composed = "caf\u{00E9}"           // U+00E9
        let decomposed = "cafe\u{0301}"        // 'e' + U+0301
        // Swift's `String ==` is Unicode-aware so the strings compare equal — but the
        // raw UTF-8 bytes differ, which is exactly what would have broken PBKDF2.
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        #expect(composed.precomposedStringWithCompatibilityMapping
                == decomposed.precomposedStringWithCompatibilityMapping)

        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: composed)
        let blob = try await km.encryptedBlob(passphrase: composed)

        // Encrypt with composed, decrypt with decomposed — must succeed.
        let restored = try await EncryptedKeyManager(blob: blob, passphrase: decomposed)
        let acct = Account(network: .mainnet)
        #expect(try await acct.address(with: km) == (try await acct.address(with: restored)))
    }

    /// v1 → current migration. We hand-craft a v1 blob (`\n`-delimited plaintext, ASCII
    /// passphrase so NFKC is a no-op) and confirm the current decoder reads it.
    @Test func v1BlobStillDecrypts() async throws {
        let mnemonic = testMnemonic
        let bip39 = "TREZOR"
        let passphrase = "ascii-pass"
        let iterations = EncryptedKeyManager.defaultIterations

        let salt = Data(repeating: 0x11, count: EncryptedKeyManager.saltLength)
        let nonceData = Data(repeating: 0x22, count: EncryptedKeyManager.nonceLength)
        let derivedKey = PBKDF2.deriveKeySHA512(
            password: Data(passphrase.utf8),  // v1 didn't normalize; ASCII is unaffected
            salt: salt,
            iterations: iterations,
            keyLength: EncryptedKeyManager.keyLength
        )
        let symKey = SymmetricKey(data: derivedKey)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        var v1Plaintext = Data(mnemonic.utf8)
        v1Plaintext.append(0x0a)
        v1Plaintext.append(Data(bip39.utf8))

        let sealed = try AES.GCM.seal(v1Plaintext, using: symKey, nonce: nonce)

        let v1Blob = EncryptedBlob(
            version: 1,
            iterations: iterations,
            saltBase64: salt.base64EncodedString(),
            nonceBase64: nonceData.base64EncodedString(),
            ciphertextBase64: sealed.ciphertext.base64EncodedString(),
            tagBase64: sealed.tag.base64EncodedString(),
            innerKind: EncryptedKeyManager.innerKindMnemonic
        )

        let restored = try await EncryptedKeyManager(blob: v1Blob, passphrase: passphrase)
        #expect(await restored.mnemonic == mnemonic)
        #expect(await restored.bip39Passphrase == bip39)

        // And the wallet derived from a v1 restore should match a fresh wallet built from
        // the same inputs — proving the v1 path produces the same downstream keys.
        let fresh = try MnemonicKeyManager(mnemonic: mnemonic, passphrase: bip39)
        let acct = Account(network: .mainnet)
        #expect(try await acct.address(with: restored) == (try await acct.address(with: fresh)))
    }
}

@Suite("FileKeyStore")
struct FileKeyStoreTests {

    @Test func saveLoadDeleteRoundTrip() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)

        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")

        try await store.save(blob, id: "wallet-a")
        let loaded = try await store.load(id: "wallet-a")
        #expect(loaded == blob)

        let listed = try await store.list()
        #expect(listed == ["wallet-a"])

        try await store.delete(id: "wallet-a")
        let afterDelete = try await store.list()
        #expect(afterDelete.isEmpty)
    }

    @Test func deleteIsIdempotent() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        // Should not throw even though "nope" was never saved.
        try await store.delete(id: "nope")
    }

    @Test func rejectsTraversalIds() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")

        for badId in ["..", "../escape", "/abs/path", "with/slash", "with space"] {
            do {
                try await store.save(blob, id: badId)
                Issue.record("Expected keystore error for id '\(badId)'")
            } catch let error as WalletError {
                if case .keystore = error { /* ok */ } else {
                    Issue.record("Unexpected: \(error)")
                }
            }
        }
    }

    @Test func multipleEntriesCoexist() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")

        try await store.save(blob, id: "alpha")
        try await store.save(blob, id: "beta")
        try await store.save(blob, id: "gamma")

        let listed = try await store.list()
        #expect(listed == ["alpha", "beta", "gamma"])
    }

    /// Saved blobs must be `0o600` regardless of process umask. Defense-in-depth — the
    /// blob is PBKDF2/AES-GCM encrypted so plaintext isn't exposed even when permissive,
    /// but limiting the file to owner-only foils a same-host attacker who guessed or
    /// keylogged the passphrase from grabbing the ciphertext at leisure.
    @Test func savedBlobsAreOwnerReadableOnly() async throws {
        #if os(Windows)
        // POSIX bits aren't meaningful on Windows; skip.
        return
        #else
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")
        try await store.save(blob, id: "wallet-a")

        let path = dir.appendingPathComponent("wallet-a.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mode = attrs[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o600)
        #endif
    }

    /// Directories created by ``FileKeyStore`` should be `0o700`. We have to use a
    /// path that doesn't yet exist — passing an already-created directory deliberately
    /// leaves the existing permissions alone.
    @Test func createdDirectoryIsOwnerOnly() throws {
        #if os(Windows)
        return
        #else
        let parent = try makeTempDir()
        let fresh = parent.appendingPathComponent("vault-\(UUID().uuidString)")
        _ = try FileKeyStore(directory: fresh)
        let attrs = try FileManager.default.attributesOfItem(atPath: fresh.path)
        let mode = attrs[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o700)
        #endif
    }

    /// Mirrors the QuickStart article's Persistence example end-to-end:
    /// encrypt mnemonic → save blob → load blob → reopen via ``Wallet/encrypted(blob:passphrase:network:provider:accountIndex:utxoStore:gapLimit:handleResolver:)``
    /// → confirm primary address matches the originally-derived one. If this test
    /// breaks, the QuickStart example is out of date.
    @Test func quickStartPersistenceFlowRoundTrips() async throws {
        let phrase = testMnemonic
        let userPassphrase = "correct horse battery staple"

        let encrypted = try await EncryptedKeyManager(
            mnemonic: phrase,
            passphrase: userPassphrase
        )
        let blob = try await encrypted.encryptedBlob(passphrase: userPassphrase)

        // QuickStart uses KeychainKeyStore; FileKeyStore exercises the same shape on
        // every platform without entitlements.
        let store = try FileKeyStore(directory: try makeTempDir())
        try await store.save(blob, id: "primary")

        let restoredBlob = try await store.load(id: "primary")
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.encrypted(
            blob: restoredBlob,
            passphrase: userPassphrase,
            network: .preprod,
            provider: .custom(make: { stub })
        )

        #expect(wallet.kind == .mnemonic)
        let expectedAddr = try await Account(network: .preprod)
            .address(with: try MnemonicKeyManager(mnemonic: phrase))
        #expect(try await wallet.primaryAddress() == expectedAddr)
    }
}

// MARK: - PBKDF2 sanity

@Suite("PBKDF2 sanity")
struct PBKDF2Tests {

    @Test func differentPassphrasesProduceDifferentKeys() {
        let salt = Data(repeating: 0xab, count: 16)
        let a = PBKDF2.deriveKeySHA512(
            password: Data("a".utf8), salt: salt, iterations: 1000, keyLength: 32
        )
        let b = PBKDF2.deriveKeySHA512(
            password: Data("b".utf8), salt: salt, iterations: 1000, keyLength: 32
        )
        #expect(a != b)
        #expect(a.count == 32)
        #expect(b.count == 32)
    }

    @Test func deterministicForSameInputs() {
        let salt = Data("salt".utf8)
        let a = PBKDF2.deriveKeySHA512(
            password: Data("password".utf8), salt: salt, iterations: 1024, keyLength: 64
        )
        let b = PBKDF2.deriveKeySHA512(
            password: Data("password".utf8), salt: salt, iterations: 1024, keyLength: 64
        )
        #expect(a == b)
        #expect(a.count == 64)
    }
}

// MARK: - SecureBytes / Data.zeroize

@Suite("Data.zeroize")
struct ZeroizeTests {

    @Test func zeroizeReplacesContentWithZeros() {
        var buf = Data([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03])
        buf.zeroize()
        #expect(buf == Data(repeating: 0, count: 7))
    }

    @Test func zeroizeIsSafeOnEmpty() {
        var buf = Data()
        buf.zeroize()  // must not crash
        #expect(buf.isEmpty)
    }
}
