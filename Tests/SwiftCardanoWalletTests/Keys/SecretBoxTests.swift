import Testing
import Foundation
@testable import SwiftCardanoWallet

@Suite("SecretBox")
struct SecretBoxTests {

    private let kind = "cli-textenvelope-v1"

    @Test("Seal then open round-trips arbitrary bytes")
    func roundTrip() throws {
        let secret = Data((0..<96).map { UInt8($0 & 0xff) })
        let blob = try SecretBox.seal(secret, passphrase: "correct horse", innerKind: kind)
        #expect(blob.innerKind == kind)
        #expect(blob.kdf == EncryptedBlob.kdfPbkdf2SHA512)
        #expect(blob.cipher == EncryptedBlob.cipherAESGCM)
        let opened = try SecretBox.open(blob, passphrase: "correct horse", expecting: kind)
        #expect(opened == secret)
    }

    @Test("Wrong passphrase fails authentication")
    func wrongPassphrase() throws {
        let blob = try SecretBox.seal(Data([1, 2, 3, 4]), passphrase: "right", innerKind: kind)
        #expect(throws: WalletError.self) {
            _ = try SecretBox.open(blob, passphrase: "wrong", expecting: kind)
        }
    }

    @Test("innerKind mismatch is rejected")
    func innerKindGuard() throws {
        let blob = try SecretBox.seal(Data([9]), passphrase: "pw", innerKind: kind)
        #expect(throws: WalletError.self) {
            _ = try SecretBox.open(blob, passphrase: "pw", expecting: "something-else")
        }
        // No expectation → any innerKind opens.
        let opened = try SecretBox.open(blob, passphrase: "pw")
        #expect(opened == Data([9]))
    }

    @Test("Tampered ciphertext fails to open")
    func tamperDetected() throws {
        var blob = try SecretBox.seal(Data(repeating: 7, count: 32), passphrase: "pw", innerKind: kind)
        var ct = Data(base64Encoded: blob.ciphertextBase64)!
        ct[0] ^= 0xff
        blob.ciphertextBase64 = ct.base64EncodedString()
        #expect(throws: WalletError.self) {
            _ = try SecretBox.open(blob, passphrase: "pw", expecting: kind)
        }
    }

    @Test("Empty passphrase is rejected on seal and open")
    func emptyPassphrase() throws {
        #expect(throws: WalletError.self) {
            _ = try SecretBox.seal(Data([1]), passphrase: "", innerKind: kind)
        }
        let blob = try SecretBox.seal(Data([1]), passphrase: "pw", innerKind: kind)
        #expect(throws: WalletError.self) {
            _ = try SecretBox.open(blob, passphrase: "", expecting: kind)
        }
    }

    @Test("Iterations below the floor are rejected")
    func lowIterationsRejected() throws {
        #expect(throws: WalletError.self) {
            _ = try SecretBox.seal(Data([1]), passphrase: "pw", innerKind: kind, iterations: 10)
        }
    }

    @Test("Distinct seals of the same secret differ (random salt + nonce)")
    func nonDeterministic() throws {
        let secret = Data([1, 2, 3])
        let a = try SecretBox.seal(secret, passphrase: "pw", innerKind: kind)
        let b = try SecretBox.seal(secret, passphrase: "pw", innerKind: kind)
        #expect(a.saltBase64 != b.saltBase64)
        #expect(a.nonceBase64 != b.nonceBase64)
        #expect(a.ciphertextBase64 != b.ciphertextBase64)
        // ...but both decrypt to the same plaintext.
        #expect(try SecretBox.open(a, passphrase: "pw") == secret)
        #expect(try SecretBox.open(b, passphrase: "pw") == secret)
    }
}
