import Foundation
import SwiftCardanoCore

/// A key manager that holds only verification keys. Useful for monitoring an address you don't
/// own (or to keep signing material on a separate device — sign offline, broadcast online).
///
/// Like ``TextEnvelopeKeyManager``, this is flat (not HD) and ignores `path.role`'s
/// index/account: `.external` / `.change` returns the loaded payment VK; `.stake` returns
/// the (optional) stake VK.
public struct WatchOnlyKeyManager: KeyManager {
    public let kind: WalletKind = .watchOnly
    public let canSign: Bool = false

    private let paymentVKey: PaymentVerificationKey
    private let stakeVKey: StakeVerificationKey?

    public init(
        paymentVerificationKey: PaymentVerificationKey,
        stakeVerificationKey: StakeVerificationKey? = nil
    ) {
        self.paymentVKey = paymentVerificationKey
        self.stakeVKey = stakeVerificationKey
    }

    public func paymentVerificationKey(at path: DerivationPath) throws -> PaymentVerificationKey {
        guard path.role == .external || path.role == .change else {
            throw WalletError.unsupportedOperation(
                "WatchOnlyKeyManager: payment VK requested at role \(path.role)"
            )
        }
        return paymentVKey
    }

    public func stakeVerificationKey(at path: DerivationPath) throws -> StakeVerificationKey {
        guard path.role == .stake else {
            throw WalletError.unsupportedOperation(
                "WatchOnlyKeyManager: stake VK requested at role \(path.role)"
            )
        }
        guard let stakeVKey else {
            throw WalletError.configurationMissing(
                "WatchOnlyKeyManager was constructed without a stake verification key"
            )
        }
        return stakeVKey
    }

    public func paymentSigningKeyType(at path: DerivationPath) throws -> SigningKeyType {
        throw WalletError.watchOnly
    }

    public func stakeSigningKeyType(at path: DerivationPath) throws -> SigningKeyType {
        throw WalletError.watchOnly
    }
}
