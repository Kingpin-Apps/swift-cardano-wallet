import Foundation

public enum WalletKind: String, Sendable, Equatable, CaseIterable {
    case mnemonic
    case textEnvelope
    case encrypted
    case watchOnly
    case multisig
    case hardware
    case offline
}
