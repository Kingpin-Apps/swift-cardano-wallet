import Testing
import Foundation
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
            _ = try await watch.paymentSigningKeyType(at: .payment())
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
