import Foundation
import SwiftCardanoCore

public enum WalletError: Error, Sendable, Equatable {
    case invalidMnemonic(String)
    case invalidPassphrase
    case watchOnly
    case insufficientFunds(required: UInt64, available: UInt64)
    case handleNotFound(String)
    case providerError(String)
    case signingFailed(String)
    case validationFailed(String)
    case submitFailed(String)
    case unsupportedOperation(String)
    case keystore(String)
    case configurationMissing(String)
    case derivationFailed(String)
}

extension WalletError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMnemonic(let detail):
            return "Invalid mnemonic: \(detail)"
        case .invalidPassphrase:
            return "Invalid passphrase."
        case .watchOnly:
            return "Operation requires signing keys; this is a watch-only wallet."
        case .insufficientFunds(let required, let available):
            return "Insufficient funds: required \(required) lovelace, have \(available)."
        case .handleNotFound(let handle):
            return "ADA Handle not found: \(handle)."
        case .providerError(let detail):
            return "Chain provider error: \(detail)"
        case .signingFailed(let detail):
            return "Signing failed: \(detail)"
        case .validationFailed(let detail):
            return "Transaction validation failed: \(detail)"
        case .submitFailed(let detail):
            return "Transaction submit failed: \(detail)"
        case .unsupportedOperation(let detail):
            return "Unsupported operation: \(detail)"
        case .keystore(let detail):
            return "Keystore error: \(detail)"
        case .configurationMissing(let detail):
            return "Configuration missing: \(detail)"
        case .derivationFailed(let detail):
            return "Key derivation failed: \(detail)"
        }
    }
}

/// Helper to build a `WalletError` from any underlying error while keeping `Sendable`.
extension WalletError {
    static func wrappingProvider(_ error: any Error) -> WalletError {
        .providerError(String(describing: error))
    }
    static func wrappingSigning(_ error: any Error) -> WalletError {
        .signingFailed(String(describing: error))
    }
    static func wrappingValidation(_ error: any Error) -> WalletError {
        .validationFailed(String(describing: error))
    }
    static func wrappingSubmit(_ error: any Error) -> WalletError {
        .submitFailed(String(describing: error))
    }
}
