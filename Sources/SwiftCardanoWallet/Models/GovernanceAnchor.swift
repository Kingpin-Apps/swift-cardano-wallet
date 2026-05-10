import Foundation
import SwiftCardanoCore

/// Friendly wrapper around `Anchor` so callers don't have to construct `Url` and
/// `AnchorDataHash` themselves. Used by every governance helper that takes an optional
/// metadata pointer (DRep registration / update, votes, proposals).
public struct GovernanceAnchor: Sendable, Equatable {

    /// HTTPS URL pointing to the metadata document (e.g. CIP-119 DRep metadata, vote rationale).
    public var url: String

    /// Hex-encoded blake2b-256 hash of the metadata document body.
    public var dataHashHex: String

    public init(url: String, dataHashHex: String) {
        self.url = url
        self.dataHashHex = dataHashHex
    }

    /// Convert to the upstream `Anchor` type used by `cardano-core`'s certificates and votes.
    public func toAnchor() throws -> Anchor {
        let urlValue: Url
        do {
            urlValue = try Url(url)
        } catch {
            throw WalletError.configurationMissing("Invalid anchor URL '\(url)': \(error)")
        }
        guard let bytes = Data(hexString: dataHashHex), bytes.count == 32 else {
            throw WalletError.configurationMissing(
                "Invalid anchor data hash (expected 32 bytes hex, got \(dataHashHex.count) chars)"
            )
        }
        return Anchor(anchorUrl: urlValue, anchorDataHash: AnchorDataHash(payload: bytes))
    }
}

private extension Data {
    init?(hexString: String) {
        let s = hexString.lowercased()
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<next], radix: 16) else { return nil }
            out.append(b)
            i = next
        }
        self = out
    }
}
