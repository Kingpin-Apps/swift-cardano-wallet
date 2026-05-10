import Foundation
import OrderedCollections
import SwiftCardanoCore

/// CIP-25 (NFT Metadata) reference label.
public let CIP25_METADATA_LABEL: TransactionMetadatumLabel = 721

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

    /// Serialize this NFT metadata into the canonical CIP-25 envelope:
    /// ```
    /// {
    ///   "<policy_id_hex>": {
    ///     "<asset_name_utf8>": {
    ///       "name": "...",
    ///       "image": "...",
    ///       ...
    ///     }
    ///   },
    ///   "version": 1
    /// }
    /// ```
    /// Returned as a `TransactionMetadatum` ready to be placed under label `721` in a `Metadata` map.
    public func encode(policyId: ScriptHash, assetName: String) -> TransactionMetadatum {
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
        policyMap[.text(assetName)] = .map(asset)

        var top: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        top[.text(policyId.payload.toHex)] = .map(policyMap)
        top[.text("version")] = .int(1)

        return .map(top)
    }
}

private extension Data {
    var toHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
