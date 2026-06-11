import Testing
import Foundation
#if os(Linux)
import Crypto
#else
import CryptoKit
#endif
import SwiftCardanoCore
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

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

    // MARK: - Generation

    @Test func generateProducesEncryptableManagerAndFreshPhrase() async throws {
        let (km, phrase) = try await EncryptedKeyManager.generate(
            passphrase: "pp",
            wordCount: 24
        )
        #expect(phrase.split(separator: " ").count == 24)

        // The returned manager must round-trip its own blob with the same passphrase.
        let blob = try await km.encryptedBlob(passphrase: "pp")
        let restored = try await EncryptedKeyManager(blob: blob, passphrase: "pp")
        #expect(await restored.mnemonic == phrase)
    }

    @Test func generateDefaultsTo24Words() async throws {
        let (_, phrase) = try await EncryptedKeyManager.generate(passphrase: "pp")
        #expect(phrase.split(separator: " ").count == 24)
    }

    @Test func generateRejectsEmptyPassphrase() async throws {
        do {
            _ = try await EncryptedKeyManager.generate(passphrase: "")
            Issue.record("Expected invalidPassphrase")
        } catch let error as WalletError {
            #expect(error == .invalidPassphrase)
        }
    }

    @Test func generateRejectsInvalidWordCount() async throws {
        do {
            _ = try await EncryptedKeyManager.generate(passphrase: "pp", wordCount: 13)
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func generateAcceptsBip39Passphrase() async throws {
        let (km, _) = try await EncryptedKeyManager.generate(
            passphrase: "pp",
            wordCount: 12,
            bip39Passphrase: "TREZOR"
        )
        #expect(await km.bip39Passphrase == "TREZOR")
    }
}
