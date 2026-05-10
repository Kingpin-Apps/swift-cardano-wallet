import Foundation

/// CIP-1852 derivation path: `m / purpose' / coin_type' / account' / role / index`.
///
/// - `purpose`  — 1852 for standard wallets, 1854 for multisig.
/// - `coinType` — 1815 (Cardano).
/// - `account`  — typically 0.
/// - `role`     — see ``Role``.
/// - `index`    — child index.
public struct DerivationPath: Sendable, Equatable, Hashable, CustomStringConvertible {

    public enum Role: UInt32, Sendable, Equatable, Hashable, CaseIterable {
        case external = 0   // receive / payment addresses
        case change = 1     // internal change addresses
        case stake = 2      // reward / stake key
        case drep = 3       // CIP-105 DRep key
        case ccCold = 4     // constitutional committee cold
        case ccHot = 5      // constitutional committee hot
    }

    public static let cardanoCoinType: UInt32 = 1815
    public static let standardPurpose: UInt32 = 1852
    public static let multisigPurpose: UInt32 = 1854

    public var purpose: UInt32
    public var coinType: UInt32
    public var account: UInt32
    public var role: Role
    public var index: UInt32

    public init(
        purpose: UInt32 = standardPurpose,
        coinType: UInt32 = cardanoCoinType,
        account: UInt32 = 0,
        role: Role,
        index: UInt32 = 0
    ) {
        self.purpose = purpose
        self.coinType = coinType
        self.account = account
        self.role = role
        self.index = index
    }

    public var description: String {
        "m/\(purpose)'/\(coinType)'/\(account)'/\(role.rawValue)/\(index)"
    }

    // MARK: Convenience constructors

    public static func payment(
        account: UInt32 = 0,
        index: UInt32 = 0,
        purpose: UInt32 = standardPurpose
    ) -> DerivationPath {
        .init(purpose: purpose, account: account, role: .external, index: index)
    }

    public static func change(
        account: UInt32 = 0,
        index: UInt32 = 0,
        purpose: UInt32 = standardPurpose
    ) -> DerivationPath {
        .init(purpose: purpose, account: account, role: .change, index: index)
    }

    public static func stake(
        account: UInt32 = 0,
        index: UInt32 = 0,
        purpose: UInt32 = standardPurpose
    ) -> DerivationPath {
        .init(purpose: purpose, account: account, role: .stake, index: index)
    }

    public static func drep(
        account: UInt32 = 0,
        index: UInt32 = 0
    ) -> DerivationPath {
        .init(purpose: standardPurpose, account: account, role: .drep, index: index)
    }
}
