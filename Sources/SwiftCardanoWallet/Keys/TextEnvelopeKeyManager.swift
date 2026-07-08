import Foundation
import SwiftCardanoCore

/// Loads `cardano-cli` `TextEnvelope` `.skey` files and exposes them through ``KeyManager``.
///
/// Supports both:
/// - **Extended** Ed25519-BIP32 keys (`PaymentExtendedSigningKeyShelley_ed25519_bip32`,
///   `StakeExtendedSigningKeyShelley_ed25519_bip32`) — what `swift-cardano-multitool generate` produces.
/// - **Non-extended** plain Ed25519 keys (`PaymentSigningKeyShelley_ed25519`,
///   `StakeSigningKeyShelley_ed25519`) — what `cardano-cli address key-gen` produces by default.
///
/// Because TextEnvelope keys are flat (not HD), this manager **ignores the role-and-index portion
/// of incoming ``DerivationPath``s**. It dispatches purely on `path.role`: `.external` / `.change`
/// returns the loaded payment key, `.stake` returns the stake key. Other roles throw.
public actor TextEnvelopeKeyManager: KeyManager {
    public nonisolated let kind: WalletKind = .textEnvelope
    public nonisolated let canSign: Bool = true

    private let paymentPayload: Data
    private let paymentIsExtended: Bool
    private let stakePayload: Data?
    private let stakeIsExtended: Bool

    /// Construct from in-memory raw payloads.
    public init(
        paymentPayload: Data,
        paymentIsExtended: Bool,
        stakePayload: Data? = nil,
        stakeIsExtended: Bool = false
    ) {
        self.paymentPayload = paymentPayload
        self.paymentIsExtended = paymentIsExtended
        self.stakePayload = stakePayload
        self.stakeIsExtended = stakeIsExtended
    }

    /// Construct by loading TextEnvelope `.skey` files from disk.
    public init(paymentKeyFile: URL, stakeKeyFile: URL? = nil) throws {
        let payment = try Self.loadSkey(from: paymentKeyFile, expecting: .payment)
        self.paymentPayload = payment.payload
        self.paymentIsExtended = payment.isExtended

        if let stakeKeyFile {
            let stake = try Self.loadSkey(from: stakeKeyFile, expecting: .stake)
            self.stakePayload = stake.payload
            self.stakeIsExtended = stake.isExtended
        } else {
            self.stakePayload = nil
            self.stakeIsExtended = false
        }
    }

    // MARK: - KeyManager

    public func paymentVerificationKey(at path: DerivationPath) throws -> PaymentVerificationKey {
        guard path.role == .external || path.role == .change else {
            throw WalletError.unsupportedOperation(
                "TextEnvelopeKeyManager: payment VK requested at role \(path.role); only .external/.change supported"
            )
        }
        if paymentIsExtended {
            let extSkey = PaymentExtendedSigningKey(
                payload: paymentPayload,
                type: PaymentExtendedSigningKey.TYPE,
                description: PaymentExtendedSigningKey.DESCRIPTION
            )
            let extVKey: PaymentExtendedVerificationKey = try extSkey.toVerificationKey()
            return try extVKey.toNonExtended()
        } else {
            let skey = PaymentSigningKey(
                payload: paymentPayload,
                type: PaymentSigningKey.TYPE,
                description: PaymentSigningKey.DESCRIPTION
            )
            return try skey.toVerificationKey()
        }
    }

    public func stakeVerificationKey(at path: DerivationPath) throws -> StakeVerificationKey {
        guard path.role == .stake else {
            throw WalletError.unsupportedOperation(
                "TextEnvelopeKeyManager: stake VK requested at role \(path.role)"
            )
        }
        guard let stakePayload else {
            throw WalletError.configurationMissing(
                "TextEnvelopeKeyManager was constructed without a stake key file"
            )
        }
        if stakeIsExtended {
            let extSkey = StakeExtendedSigningKey(
                payload: stakePayload,
                type: StakeExtendedSigningKey.TYPE,
                description: StakeExtendedSigningKey.DESCRIPTION
            )
            let extVKey: StakeExtendedVerificationKey = try extSkey.toVerificationKey()
            return try extVKey.toNonExtended()
        } else {
            let skey = StakeSigningKey(
                payload: stakePayload,
                type: StakeSigningKey.TYPE,
                description: StakeSigningKey.DESCRIPTION
            )
            return try skey.toVerificationKey()
        }
    }

    public func paymentSigningKeyType(at path: DerivationPath) throws -> SigningKeyType {
        guard path.role == .external || path.role == .change else {
            throw WalletError.unsupportedOperation(
                "TextEnvelopeKeyManager: payment signing key requested at role \(path.role)"
            )
        }
        if paymentIsExtended {
            return .extendedSigningKey(
                PaymentExtendedSigningKey(
                    payload: paymentPayload,
                    type: PaymentExtendedSigningKey.TYPE,
                    description: PaymentExtendedSigningKey.DESCRIPTION
                )
            )
        } else {
            return .signingKey(
                PaymentSigningKey(
                    payload: paymentPayload,
                    type: PaymentSigningKey.TYPE,
                    description: PaymentSigningKey.DESCRIPTION
                )
            )
        }
    }

    public func stakeSigningKeyType(at path: DerivationPath) throws -> SigningKeyType {
        guard path.role == .stake else {
            throw WalletError.unsupportedOperation(
                "TextEnvelopeKeyManager: stake signing key requested at role \(path.role)"
            )
        }
        guard let stakePayload else {
            throw WalletError.configurationMissing(
                "TextEnvelopeKeyManager was constructed without a stake key file"
            )
        }
        if stakeIsExtended {
            return .extendedSigningKey(
                StakeExtendedSigningKey(
                    payload: stakePayload,
                    type: StakeExtendedSigningKey.TYPE,
                    description: StakeExtendedSigningKey.DESCRIPTION
                )
            )
        } else {
            return .signingKey(
                StakeSigningKey(
                    payload: stakePayload,
                    type: StakeSigningKey.TYPE,
                    description: StakeSigningKey.DESCRIPTION
                )
            )
        }
    }

    // MARK: - Parsing

    /// Which role a `.skey` file is expected to carry — payment or stake.
    public enum SkeyRole: Sendable {
        case payment, stake
    }

    /// The raw signing material extracted from a TextEnvelope `.skey` file: the payload bytes and
    /// whether the key is an extended (Ed25519-BIP32, 128-byte) or plain (Ed25519, 32-byte) key.
    /// Feed these straight into ``init(paymentPayload:paymentIsExtended:stakePayload:stakeIsExtended:)``
    /// or persist them (encrypted) for later reconstruction — no temp file ever required.
    public struct ParsedSkey: Sendable, Equatable {
        public let payload: Data
        public let isExtended: Bool

        public init(payload: Data, isExtended: Bool) {
            self.payload = payload
            self.isExtended = isExtended
        }
    }

    /// Parse the bytes of a `cardano-cli` TextEnvelope `.skey` file into its raw signing payload,
    /// validating that the envelope `type` matches the expected `role`. Purely in-memory: lets an
    /// app read a user-supplied `.skey`, seal the payload, and never write the plaintext key to disk.
    public static func parseSkey(_ data: Data, role: SkeyRole) throws -> ParsedSkey {
        let loaded = try loadSkey(data: data, expecting: role, source: "<data>")
        return ParsedSkey(payload: loaded.payload, isExtended: loaded.isExtended)
    }

    // MARK: - File loading

    private struct LoadedSkey {
        let payload: Data
        let isExtended: Bool
    }

    private struct TextEnvelopeFile: Decodable {
        let type: String
        let description: String?
        let cborHex: String
    }

    private static func loadSkey(from url: URL, expecting kind: SkeyRole) throws -> LoadedSkey {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WalletError.configurationMissing("Cannot read \(url.path): \(error)")
        }
        return try loadSkey(data: data, expecting: kind, source: url.path)
    }

    private static func loadSkey(data: Data, expecting kind: SkeyRole, source: String) throws -> LoadedSkey {
        let envelope: TextEnvelopeFile
        do {
            envelope = try JSONDecoder().decode(TextEnvelopeFile.self, from: data)
        } catch {
            throw WalletError.configurationMissing("Not a valid TextEnvelope file at \(source): \(error)")
        }

        let acceptedTypes: [String]
        switch kind {
        case .payment:
            acceptedTypes = [
                PaymentExtendedSigningKey.TYPE,
                PaymentSigningKey.TYPE,
            ]
        case .stake:
            acceptedTypes = [
                StakeExtendedSigningKey.TYPE,
                StakeSigningKey.TYPE,
            ]
        }
        guard acceptedTypes.contains(envelope.type) else {
            throw WalletError.configurationMissing(
                "TextEnvelope at \(source) has unsupported type '\(envelope.type)' (expected one of \(acceptedTypes))"
            )
        }

        let isExtended = envelope.type.contains("Extended")
        let payload = try decodeCBORHex(envelope.cborHex, expectedLength: isExtended ? 128 : 32)
        return LoadedSkey(payload: payload, isExtended: isExtended)
    }

    /// Strip the `cardano-cli` CBOR byte-string wrapping (`5820…` for 32 bytes,
    /// `5880…` / `58 80 …` for 128 bytes) and return the raw payload.
    private static func decodeCBORHex(_ hex: String, expectedLength: Int) throws -> Data {
        guard let raw = Data(hexString: hex) else {
            throw WalletError.configurationMissing("Invalid cborHex: \(hex.prefix(8))…")
        }
        // CBOR major type 2 (byte string) prefixes:
        //   0x58 <len:1>      for 24..255 bytes
        // 32-byte payload  → 0x58 0x20 …
        // 128-byte payload → 0x58 0x80 …
        guard raw.count >= 2, raw[0] == 0x58 else {
            // Some files store raw bytes without CBOR wrapping; accept that too if length matches.
            if raw.count == expectedLength { return raw }
            throw WalletError.configurationMissing(
                "Unexpected cborHex format: prefix \(String(format: "%02x", raw[0])); length \(raw.count)"
            )
        }
        let len = Int(raw[1])
        guard len == expectedLength, raw.count == 2 + len else {
            // length mismatch — if outer raw length matches, fall back
            if raw.count == expectedLength { return raw }
            throw WalletError.configurationMissing(
                "cborHex length mismatch: declared \(len), expected \(expectedLength), raw \(raw.count)"
            )
        }
        return raw.subdata(in: 2..<raw.count)
    }
}

