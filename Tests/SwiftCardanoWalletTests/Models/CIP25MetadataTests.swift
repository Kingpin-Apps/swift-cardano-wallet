import Testing
import Foundation
import OrderedCollections
import SwiftCardanoCore
@testable import SwiftCardanoWallet

@Suite("CIP-25 v2 encoding")
struct CIP25v2Tests {

    private func policyId() throws -> ScriptHash {
        ScriptHash(payload: Data(repeating: 0xab, count: 28))
    }

    private func sampleMetadata() -> CIP25NFTMetadata {
        CIP25NFTMetadata(
            name: "MyNFT",
            image: "ipfs://abc",
            mediaType: "image/png",
            description: "A test NFT"
        )
    }

    @Test func v1EncodingKeysAssetNameAsText() throws {
        let metadata = sampleMetadata()
        let encoded = metadata.encode(policyId: try policyId(), assetName: "MyNFT", version: .v1)

        guard case .map(let outer) = encoded else {
            Issue.record("Expected outer map"); return
        }
        // version: 1 at top level.
        let versionValue = outer[.text("version")]
        guard case .int(let v) = versionValue else {
            Issue.record("Missing or non-int version: \(String(describing: versionValue))"); return
        }
        #expect(v == 1)

        // Policy entry exists.
        let hex = String(repeating: "ab", count: 28)
        guard case .map(let policyMap) = outer[.text(hex)] else {
            Issue.record("Expected policy map under '\(hex)'"); return
        }
        // Asset name keyed as .text.
        #expect(policyMap[.text("MyNFT")] != nil)
        #expect(policyMap[.bytes(Data("MyNFT".utf8))] == nil)
    }

    @Test func v2EncodingKeysAssetNameAsBytes() throws {
        let metadata = sampleMetadata()
        let encoded = metadata.encode(policyId: try policyId(), assetName: "MyNFT", version: .v2)

        guard case .map(let outer) = encoded else {
            Issue.record("Expected outer map"); return
        }
        // version: 2 at top level.
        let versionValue = outer[.text("version")]
        guard case .int(let v) = versionValue else {
            Issue.record("Missing version"); return
        }
        #expect(v == 2)

        let hex = String(repeating: "ab", count: 28)
        guard case .map(let policyMap) = outer[.text(hex)] else {
            Issue.record("Expected policy map under '\(hex)'"); return
        }
        // Asset name keyed as .bytes (UTF-8 of "MyNFT").
        #expect(policyMap[.bytes(Data("MyNFT".utf8))] != nil)
        #expect(policyMap[.text("MyNFT")] == nil)
    }

    @Test func v2DefaultIsV1ForBackwardsCompatibility() throws {
        let metadata = sampleMetadata()
        // No `version:` argument → v1.
        let encoded = metadata.encode(policyId: try policyId(), assetName: "MyNFT")
        guard case .map(let outer) = encoded else {
            Issue.record("Expected outer map"); return
        }
        guard case .int(let v) = outer[.text("version")] else {
            Issue.record("Missing version"); return
        }
        #expect(v == 1)
    }

    @Test func v2AcceptsRawByteAssetName() throws {
        // CIP-67-style prefixed asset name (4 bytes prefix + 28 bytes data).
        let assetNameBytes = Data([0x00, 0x06, 0x43, 0xb0]) + Data(repeating: 0x42, count: 28)
        let metadata = sampleMetadata()
        let encoded = metadata.encode(policyId: try policyId(), assetNameBytes: assetNameBytes)

        guard case .map(let outer) = encoded else {
            Issue.record("Expected outer map"); return
        }
        guard case .int(let v) = outer[.text("version")] else {
            Issue.record("Missing version"); return
        }
        #expect(v == 2)  // bytes overload forces v2

        let hex = String(repeating: "ab", count: 28)
        guard case .map(let policyMap) = outer[.text(hex)] else {
            Issue.record("Expected policy map"); return
        }
        // Asset key is .bytes with our supplied bytes verbatim.
        #expect(policyMap[.bytes(assetNameBytes)] != nil)
    }

    @Test func v2WithNonAsciiAssetName() throws {
        // Emoji asset name — works in v2 (bytes), would still encode in v1 but with text
        // key (some explorers / wallets choke on that).
        let name = "🦄💎"
        let metadata = sampleMetadata()
        let encoded = metadata.encode(policyId: try policyId(), assetName: name, version: .v2)

        guard case .map(let outer) = encoded else {
            Issue.record("Expected outer map"); return
        }
        let hex = String(repeating: "ab", count: 28)
        guard case .map(let policyMap) = outer[.text(hex)] else {
            Issue.record("Expected policy map"); return
        }
        // The asset key is the UTF-8 bytes of the emoji string.
        #expect(policyMap[.bytes(Data(name.utf8))] != nil)
    }

    @Test func v1AndV2HaveDifferentCBORShape() throws {
        let metadata = sampleMetadata()
        let v1 = metadata.encode(policyId: try policyId(), assetName: "MyNFT", version: .v1)
        let v2 = metadata.encode(policyId: try policyId(), assetName: "MyNFT", version: .v2)
        #expect(v1 != v2)
    }
}
