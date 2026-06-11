import Foundation
#if canImport(Glibc)
import Glibc
#endif

extension Data {
    /// Overwrite the buffer with zeros, attempting to resist dead-store elimination
    /// by the optimizer via `memset_s`. Use after sensitive intermediates (PBKDF2
    /// derived keys, decrypted plaintext) so they don't linger on the heap until ARC.
    ///
    /// **Caveats — defense-in-depth, not a guarantee.**
    ///
    /// - `Data` is copy-on-write. If the receiver shares storage with a previous
    ///   reference (e.g. produced via a slice or `Data(otherData)`), this method
    ///   triggers a COW copy and zeros the *new* allocation, leaving the original
    ///   bytes intact. Use only on freshly-allocated buffers you own.
    /// - Downstream `Data` consumers (CryptoKit's `SymmetricKey(data:)`, etc.) make
    ///   internal copies we can't reach. Zeroing one heap copy still removes one of
    ///   the residue paths.
    /// - On systems with swap enabled, the bytes may have already been paged out
    ///   before this call. Use `mlock`-style protection at a lower layer if that
    ///   matters.
    mutating func zeroize() {
        guard !isEmpty else { return }
        let length = count
        withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            #if canImport(Glibc)
            explicit_bzero(base, length)
            #else
            _ = memset_s(base, length, 0, length)
            #endif
        }
    }
}
