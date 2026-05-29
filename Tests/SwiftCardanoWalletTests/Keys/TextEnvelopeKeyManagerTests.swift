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
