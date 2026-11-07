import BigInt
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
    ///
    /// Throws ``WalletError/configurationMissing(_:)`` when the handle resolves to an
    /// address on another network, or to anything other than a key-hash payment address
    /// (script, stake-only). Outputs built here carry no datum, so sending to a script
    /// address could lock the funds.
    public func prepareSendTo(
        handle: String,
        lovelace: UInt64
    ) async throws -> PreparedTransaction {
        let address = try await resolveHandle(handle)
        guard address.network == network.networkId else {
            throw WalletError.configurationMissing(
                "Handle \(handle) resolved to an address on another network"
            )
        }
        guard case .verificationKeyHash? = address.paymentPart else {
            throw WalletError.configurationMissing(
                "Handle \(handle) does not resolve to a key-hash payment address"
            )
        }
        return try await prepareSend(lovelace: lovelace, to: address)
    }

    /// One-shot: resolve, build, sign, submit. Returns the transaction id reported by the
    /// chain backend.
    @discardableResult
    public func sendTo(handle: String, lovelace: UInt64) async throws -> String {
        let prepared = try await prepareSendTo(handle: handle, lovelace: lovelace)
        let signed = try await prepared.sign()
        return try await signed.submit()
    }
}
