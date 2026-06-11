import Foundation
#if os(Linux)
import Crypto
#else
import CryptoKit
#endif

/// Minimal PBKDF2-HMAC-SHA512 implementation. CryptoKit doesn't expose PBKDF2 directly
/// (only HKDF, which isn't a password-stretching KDF), so we build it on top of `HMAC<SHA512>`.
///
/// Spec: RFC 2898 §5.2.
enum PBKDF2 {
    static func deriveKeySHA512(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        precondition(iterations > 0, "iterations must be > 0")
        precondition(keyLength > 0, "keyLength must be > 0")
        let hLen = SHA512.byteCount  // 64
        let blocks = Int((Double(keyLength) / Double(hLen)).rounded(.up))

        let key = SymmetricKey(data: password)
        var derived = Data(capacity: blocks * hLen)

        for i in 1...blocks {
            // U_1 = HMAC(P, S || INT_32_BE(i))
            var message = salt
            message.append(UInt8((i >> 24) & 0xff))
            message.append(UInt8((i >> 16) & 0xff))
            message.append(UInt8((i >>  8) & 0xff))
            message.append(UInt8( i        & 0xff))

            var u = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
            var t = u

            // U_j = HMAC(P, U_{j-1}); T_i = U_1 XOR U_2 XOR ... XOR U_c
            for _ in 1..<iterations {
                u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                for idx in 0..<hLen {
                    t[idx] ^= u[idx]
                }
            }
            derived.append(t)
        }

        return derived.prefix(keyLength)
    }
}
