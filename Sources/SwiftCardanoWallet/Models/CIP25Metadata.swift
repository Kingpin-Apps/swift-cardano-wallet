import Foundation
import OrderedCollections
import SwiftCardanoCore

/// CIP-25 (NFT Metadata) reference label.
public let CIP25_METADATA_LABEL: TransactionMetadatumLabel = 721

/// Which version of CIP-25 to emit.
///
/// - ``v1``: asset names keyed as **text** strings (`assetName: String` is UTF-8 decoded
///   on chain). Backwards-compatible with old wallets; works for ASCII names ≤ 32 bytes.
/// - ``v2``: asset names keyed as **byte strings**. Required for non-ASCII names or
///   asset-name representations that don't round-trip through UTF-8. Top-level metadata
///   carries `"version": 2`.
public enum CIP25Version: Int, Sendable, Equatable {
    case v1 = 1
    case v2 = 2
}

/// Single file referenced by a CIP-25 NFT (e.g. extra resolutions, video, etc.).
public struct CIP25File: Sendable, Equatable {
    public var name: String
    public var mediaType: String
    public var src: String          // URI; CIP-25 also allows arrays of strings split into 64-char chunks but we keep it simple

    public init(name: String, mediaType: String, src: String) {
        self.name = name
        self.mediaType = mediaType
        self.src = src
    }
}

/// CIP-25 (v1) NFT metadata payload — the per-asset record under
/// `721 → <policy_id_hex> → <asset_name_string>`.
///
/// Use ``encode(policyId:assetName:)`` to wrap this into a full CIP-25 envelope ready to be
/// attached to a transaction's `AuxiliaryData`.
public struct CIP25NFTMetadata: Sendable, Equatable {
    public var name: String
    public var image: String
    public var mediaType: String?
    public var description: String?
    public var files: [CIP25File]?
    /// Free-form extra string fields. Keys appended at the top level of the asset record.
    public var extras: [String: String]?

    public init(
        name: String,
        image: String,
        mediaType: String? = nil,
        description: String? = nil,
        files: [CIP25File]? = nil,
        extras: [String: String]? = nil
    ) {
        self.name = name
        self.image = image
        self.mediaType = mediaType
        self.description = description
        self.files = files
        self.extras = extras
    }

    /// Serialize this NFT metadata into the canonical CIP-25 envelope. Defaults to
    /// **v1** for backwards compatibility — pass `version: .v2` for non-ASCII asset names
    /// or wallets that require the v2 byte-keyed asset map.
    ///
    /// **v1 shape:**
    /// ```
    /// {
    ///   "<policy_id_hex>": { "<asset_name_utf8>": { "name": "...", "image": "...", ... } },
    ///   "version": 1
    /// }
    /// ```
    ///
    /// **v2 shape:**
    /// ```
    /// {
    ///   "<policy_id_hex>": { <asset_name_bytes>: { "name": "...", "image": "...", ... } },
    ///   "version": 2
    /// }
    /// ```
    ///
    /// Returned as a `TransactionMetadatum` ready to be placed under label `721` in a
    /// `Metadata` map.
    public func encode(
        policyId: ScriptHash,
        assetName: String,
        version: CIP25Version = .v1
    ) -> TransactionMetadatum {
        // v2 keys asset names by raw bytes; we accept a `String` and decode as UTF-8.
        // For non-UTF-8 / pre-encoded asset names use ``encode(policyId:assetNameBytes:version:)``.
        let assetKey: TransactionMetadatum
        switch version {
        case .v1: assetKey = .text(assetName)
        case .v2: assetKey = .bytes(Data(assetName.utf8))
        }
        return encode(
            policyId: policyId,
            assetKey: assetKey,
            version: version
        )
    }

    /// Variant of ``encode(policyId:assetName:version:)`` that takes a raw byte asset
    /// name. Used for **v2** when the on-chain asset name isn't a UTF-8 string
    /// (e.g. CIP-67 / CIP-68 prefixed assets). Forces `version: .v2` if `.v1` is passed
    /// with bytes — v1 doesn't support byte-keyed asset names.
    public func encode(
        policyId: ScriptHash,
        assetNameBytes: Data,
        version: CIP25Version = .v2
    ) -> TransactionMetadatum {
        return encode(
            policyId: policyId,
            assetKey: .bytes(assetNameBytes),
            version: .v2  // bytes ⇒ always v2
        )
    }

    // MARK: - Internals

    private func encode(
        policyId: ScriptHash,
        assetKey: TransactionMetadatum,
        version: CIP25Version
    ) -> TransactionMetadatum {
        var asset: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        asset[.text("name")] = .text(name)
        asset[.text("image")] = .text(image)
        if let mediaType { asset[.text("mediaType")] = .text(mediaType) }
        if let description { asset[.text("description")] = .text(description) }
        if let files {
            let fileEntries: [TransactionMetadatum] = files.map { file in
                var fd: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
                fd[.text("name")] = .text(file.name)
                fd[.text("mediaType")] = .text(file.mediaType)
                fd[.text("src")] = .text(file.src)
                return .map(fd)
            }
            asset[.text("files")] = .list(fileEntries)
        }
        if let extras {
            for (k, v) in extras.sorted(by: { $0.key < $1.key }) {
                asset[.text(k)] = .text(v)
            }
        }

        var policyMap: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        policyMap[assetKey] = .map(asset)

        var top: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        top[.text(policyId.payload.toHex)] = .map(policyMap)
        top[.text("version")] = .int(version.rawValue)

        return .map(top)
    }
}

