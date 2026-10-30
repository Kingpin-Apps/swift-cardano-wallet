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
    /// The file's URI. One longer than the ledger's 64-byte metadata string is written as
    /// CIP-25's array of chunks.
    public var src: String

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
    ///
    /// The ledger rejects metadata holding a string longer than 64 bytes, so `image`,
    /// `description`, each file's `src` and the extras are written as CIP-25's arrays of
    /// ≤ 64-byte chunks when they are longer.
    /// - Throws: ``WalletError/validationFailed(_:)`` when a field CIP-25 keeps as one
    ///   string — `name`, `mediaType`, a file's `name` or `mediaType`, or a v1 asset name —
    ///   is longer than 64 bytes.
    public func encode(
        policyId: ScriptHash,
        assetName: String,
        version: CIP25Version = .v1
    ) throws -> TransactionMetadatum {
        // v2 keys asset names by raw bytes; we accept a `String` and decode as UTF-8.
        // For non-UTF-8 / pre-encoded asset names use ``encode(policyId:assetNameBytes:version:)``.
        let assetKey: TransactionMetadatum
        switch version {
        case .v1: assetKey = .text(assetName)
        case .v2: assetKey = .bytes(Data(assetName.utf8))
        }
        return try encode(
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
    ) throws -> TransactionMetadatum {
        return try encode(
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
    ) throws -> TransactionMetadatum {
        if case .text(let key) = assetKey {
            try Self.checkString(key, "asset name")
        }
        var asset: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        try Self.checkString(name, "name")
        asset[.text("name")] = .text(name)
        asset[.text("image")] = Self.chunked(image)
        if let mediaType {
            try Self.checkString(mediaType, "mediaType")
            asset[.text("mediaType")] = .text(mediaType)
        }
        if let description { asset[.text("description")] = Self.chunked(description) }
        if let files {
            let fileEntries: [TransactionMetadatum] = try files.map { file in
                try Self.checkString(file.name, "file name")
                try Self.checkString(file.mediaType, "file mediaType")
                var fd: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
                fd[.text("name")] = .text(file.name)
                fd[.text("mediaType")] = .text(file.mediaType)
                fd[.text("src")] = Self.chunked(file.src)
                return .map(MapPairs(fd))
            }
            asset[.text("files")] = .list(fileEntries)
        }
        if let extras {
            for (k, v) in extras.sorted(by: { $0.key < $1.key }) {
                try Self.checkString(k, "extra key")
                asset[.text(k)] = Self.chunked(v)
            }
        }

        var policyMap: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        policyMap[assetKey] = .map(MapPairs(asset))

        var top: OrderedDictionary<TransactionMetadatum, TransactionMetadatum> = [:]
        top[.text(policyId.payload.toHex)] = .map(MapPairs(policyMap))
        top[.text("version")] = .int(version.rawValue)

        return .map(MapPairs(top))
    }

    /// The most bytes a metadata string may hold: the ledger rejects a transaction whose
    /// metadata holds a longer one (`InvalidMetadata`).
    static let maxStringBytes = 64

    /// `text` as one metadata string, or as CIP-25's array of strings of at most
    /// ``maxStringBytes`` bytes each, split between characters.
    static func chunked(_ text: String) -> TransactionMetadatum {
        guard text.utf8.count > maxStringBytes else { return .text(text) }
        var chunks: [TransactionMetadatum] = []
        var chunk = ""
        for character in text {
            if chunk.utf8.count + String(character).utf8.count > maxStringBytes {
                chunks.append(.text(chunk))
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { chunks.append(.text(chunk)) }
        return .list(chunks)
    }

    /// Throws when `text`, which CIP-25 keeps as one string, is too long for the ledger.
    static func checkString(_ text: String, _ field: String) throws {
        guard text.utf8.count <= maxStringBytes else {
            throw WalletError.validationFailed(
                "CIP-25 \(field) is \(text.utf8.count) bytes; a metadata string holds at most \(maxStringBytes)")
        }
    }
}
