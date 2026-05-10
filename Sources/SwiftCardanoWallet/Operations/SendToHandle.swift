import Foundation
import SwiftCardanoCore

extension MnemonicWallet {

    /// Resolve an ADA Handle (`$alice`, `$alice.subhandle`, etc.) into a Cardano `Address`
    /// using the wallet's configured ``HandleResolver``.
    ///
    /// Throws ``WalletError/configurationMissing(_:)`` if the wallet was built without a
    /// resolver (the `handleResolver:` init parameter was nil).
    public func resolveHandle(_ handle: String) async throws -> Address {
        guard let resolver = handleResolver else {
            throw WalletError.configurationMissing(
                "No HandleResolver configured. Pass a `handleResolver:` to MnemonicWallet.init."
            )
        }
        return try await resolver.resolve(handle)
    }

    /// Build (but do not sign or submit) a transaction sending `lovelace` to the address
    /// behind an ADA Handle. Convenience over `prepareSend(lovelace:to:)`.
    public func prepareSendTo(
        handle: String,
        lovelace: Int
    ) async throws -> PreparedTransaction {
        let address = try await resolveHandle(handle)
        return try await prepareSend(lovelace: lovelace, to: address)
    }

    /// One-shot: resolve, build, sign, submit. Returns the transaction id reported by the
    /// chain backend.
    @discardableResult
    public func sendTo(handle: String, lovelace: Int) async throws -> String {
        let prepared = try await prepareSendTo(handle: handle, lovelace: lovelace)
        let signed = try await prepared.sign()
        return try await signed.submit()
    }
}
