import Testing
import Foundation
@testable import SwiftCardanoWallet

@Suite("EncryptedBlob")
struct EncryptedBlobTests {

    private func sample() -> EncryptedBlob {
        EncryptedBlob(
            iterations: 210_000,
            saltBase64: Data(repeating: 0xab, count: 16).base64EncodedString(),
            nonceBase64: Data(repeating: 0xcd, count: 12).base64EncodedString(),
            ciphertextBase64: Data(repeating: 0xef, count: 64).base64EncodedString(),
            tagBase64: Data(repeating: 0x12, count: 16).base64EncodedString(),
            innerKind: EncryptedKeyManager.innerKindMnemonic
        )
    }

    @Test func jsonRoundTrip() throws {
        let blob = sample()
        let data = try blob.toJSONData()
        let restored = try EncryptedBlob.fromJSONData(data)
        #expect(blob == restored)
    }

    @Test func defaultsToCurrentVersion() {
        let blob = sample()
        #expect(blob.version == EncryptedBlob.currentVersion)
        #expect(blob.kdf == EncryptedBlob.kdfPbkdf2SHA512)
        #expect(blob.cipher == EncryptedBlob.cipherAESGCM)
    }

    @Test func jsonOutputIsSortedAndStable() throws {
        let blob = sample()
        let data1 = try blob.toJSONData()
        let data2 = try blob.toJSONData()
        #expect(data1 == data2)
        // Spot-check ordering: `cipher` should appear before `iterations` lexicographically.
        let json = String(decoding: data1, as: UTF8.self)
        if let cipherIdx = json.range(of: "\"cipher\""),
           let iterIdx = json.range(of: "\"iterations\"") {
            #expect(cipherIdx.lowerBound < iterIdx.lowerBound)
        } else {
            Issue.record("Expected both \"cipher\" and \"iterations\" keys in JSON")
        }
    }

    @Test func versionFloorIsBelowCurrent() {
        // Sanity check that the migration window covers at least one legacy version.
        #expect(EncryptedBlob.minSupportedVersion < EncryptedBlob.currentVersion)
        #expect(EncryptedBlob.minSupportedVersion >= 1)
    }

    @Test func corruptJSONFailsToDecode() throws {
        let bad = Data("not json".utf8)
        do {
            _ = try EncryptedBlob.fromJSONData(bad)
            Issue.record("Expected JSON decoding error")
        } catch {
            // expected
        }
    }
}
