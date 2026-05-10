import Foundation
import SwiftCardanoCore

/// One signer's hardware-wallet key files. Pre-generated once via
/// `cardano-hw-cli address key-gen`, the user supplies the resulting `.hwsfile` (used by the
/// device for signing) plus the matching `.vkey` (public key TextEnvelope used by the wallet
/// for in-process address derivation, no device needed).
///
/// Both paths must already exist on disk. The wallet validates the `.vkey` lazily when first
/// used; the `.hwsfile` is only opened during ``PreparedHardwareTransaction/signWithDevice()``.
public struct HardwareKeyFile: Sendable, Equatable {

    public enum Role: String, Sendable, Equatable {
        case payment
        case stake
    }

    /// Path to the `.hwsfile` produced by `cardano-hw-cli address key-gen` (or equivalent).
    public let hwsfilePath: String

    /// Path to the matching `.vkey` (TextEnvelope) — the verification key for the same
    /// derivation path. Used to derive addresses without device interaction.
    public let vkeyPath: String

    /// What kind of credential this key represents.
    public let role: Role

    public init(hwsfilePath: String, vkeyPath: String, role: Role) {
        self.hwsfilePath = hwsfilePath
        self.vkeyPath = vkeyPath
        self.role = role
    }

    /// Load the verification key from disk. Cached by the caller; we don't memoize here so
    /// the value type stays cheap to copy.
    ///
    /// Discriminates extended vs non-extended by inspecting the TextEnvelope `type` field
    /// (cardano-hw-cli emits `*VerificationKeyShelley_ed25519` for 32-byte keys and
    /// `*ExtendedVerificationKeyShelley_ed25519` for 64-byte keys). The upstream
    /// ``SwiftCardanoCore/VerificationKeyType/load(from:)`` checks the CBOR-encoded byte
    /// length, which is always payload+2, so it mis-classifies all keys as extended; we
    /// avoid that path.
    public func loadVerificationKey() throws -> VerificationKeyType {
        let typeField: String
        do {
            typeField = try Self.readTypeField(at: vkeyPath)
        } catch {
            throw WalletError.configurationMissing(
                "Failed to load \(role) verification key from '\(vkeyPath)': \(error)"
            )
        }

        do {
            if typeField.lowercased().contains("extended") {
                let v = try ExtendedVerificationKey.load(from: vkeyPath)
                return .extendedVerificationKey(v)
            } else {
                let v = try VerificationKey.load(from: vkeyPath)
                return .verificationKey(v)
            }
        } catch {
            throw WalletError.configurationMissing(
                "Failed to load \(role) verification key from '\(vkeyPath)': \(error)"
            )
        }
    }

    private static func readTypeField(at path: String) throws -> String {
        let jsonString = try String(contentsOfFile: path, encoding: .utf8)
        guard
            let data = jsonString.data(using: .utf8),
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: String],
            let type = dict["type"]
        else {
            throw WalletError.configurationMissing("Invalid TextEnvelope JSON at '\(path)'.")
        }
        return type
    }

    /// Hash the verification key (blake2b-224). Falls back to extracting the 32-byte
    /// non-extended payload when the file is an extended (64-byte) vkey.
    public func keyHash() throws -> VerificationKeyHash {
        let vkey = try loadVerificationKey()
        switch vkey {
        case .verificationKey(let v):
            return try v.hash()
        case .extendedVerificationKey(let v):
            // `hash()` on the extended protocol returns `(hash, trimmed-key)` because it
            // also constructs the non-extended counterpart along the way. We only want the
            // hash here.
            let result: (VerificationKeyHash, VerificationKey) = try v.hash()
            return result.0
        }
    }
}
