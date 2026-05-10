import Foundation
import SwiftCardanoCore

/// A single cosigner's contribution to a multisig transaction. Wraps one
/// ``SwiftCardanoCore/VerificationKeyWitness`` plus the body hash it signs over so the
/// combiner can reject mismatched partials before assembling the final witness set.
///
/// The full lifecycle is:
/// 1. The coordinator builds an unsigned ``PreparedMultisigTransaction`` and ships its CBOR
///    (plus the body hash) to each cosigner.
/// 2. Each cosigner verifies the body, signs it locally with
///    ``PreparedMultisigTransaction/signLocal(with:)``, and ships the resulting
///    ``PartialWitness`` back.
/// 3. The coordinator calls ``PreparedMultisigTransaction/combine(_:)`` with at least the
///    threshold-many partials to produce a ``SignedTransaction``.
public struct PartialWitness: Sendable, Equatable {

    /// 32-byte blake2b-256 hash of the transaction body the witness signs.
    public let bodyHash: Data

    /// The vkey witness produced by the cosigner.
    public let witness: VerificationKeyWitness

    public init(bodyHash: Data, witness: VerificationKeyWitness) {
        self.bodyHash = bodyHash
        self.witness = witness
    }

    /// CBOR encoding suitable for transport (file, QR code, RPC). Produces a 2-element array:
    /// `[bodyHashBytes, vkeyWitnessCBOR]`. Uses `Primitive`'s own CBOR codec so we don't have
    /// to depend on `PotentCBOR` directly.
    public func exportCBOR() throws -> Data {
        do {
            let witnessCBOR = try witness.toCBORData()
            let envelope = Primitive.list([.bytes(bodyHash), .bytes(witnessCBOR)])
            return try envelope.toCBORData()
        } catch {
            throw WalletError.signingFailed("Failed to encode PartialWitness: \(error)")
        }
    }

    /// Reverse of ``exportCBOR()``. Tolerant of a re-wrapped vkey witness CBOR (the inner
    /// `VerificationKeyWitness` decoder validates byte lengths).
    public static func fromCBOR(_ data: Data) throws -> PartialWitness {
        let primitive: Primitive
        do {
            primitive = try Primitive.fromCBOR(data: data)
        } catch {
            throw WalletError.signingFailed("Invalid PartialWitness CBOR: \(error)")
        }
        guard
            case .list(let outer) = primitive,
            outer.count == 2,
            case .bytes(let bodyHashBytes) = outer[0],
            case .bytes(let witnessBytes) = outer[1]
        else {
            throw WalletError.signingFailed("PartialWitness CBOR must be [hash, witness].")
        }
        let witness: VerificationKeyWitness
        do {
            witness = try VerificationKeyWitness.fromCBOR(data: witnessBytes)
        } catch {
            throw WalletError.signingFailed("Failed to decode VerificationKeyWitness: \(error)")
        }
        return PartialWitness(bodyHash: bodyHashBytes, witness: witness)
    }
}

