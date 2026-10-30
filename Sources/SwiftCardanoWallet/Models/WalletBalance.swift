import BigInt
import Foundation
import SwiftCardanoCore

/// Aggregate balance over a wallet's tracked UTxOs.
///
/// `lovelace` is the native ADA amount (1 ADA = 1_000_000 lovelace). `multiAsset` aggregates
/// every native token currently held. `rewards` is the unwithdrawn stake-account balance,
/// reported by `ChainContext.stakeAddressInfo` — `0` if the stake address isn't registered,
/// and `nil` when it was not read: the wallet has no reward account it queries, or the
/// query failed. `utxoCount` is the number of UTxOs that contributed to the totals.
public struct WalletBalance: Sendable, Equatable {
    public let lovelace: UInt64
    public let multiAsset: MultiAsset
    public let rewards: UInt64?
    public let utxoCount: Int

    public init(
        lovelace: UInt64,
        multiAsset: MultiAsset = MultiAsset([:]),
        rewards: UInt64? = nil,
        utxoCount: Int
    ) {
        self.lovelace = lovelace
        self.multiAsset = multiAsset
        self.rewards = rewards
        self.utxoCount = utxoCount
    }

    public static let zero = WalletBalance(
        lovelace: 0,
        multiAsset: MultiAsset([:]),
        rewards: 0,
        utxoCount: 0
    )

    /// The balance of `utxos`, with `rewards` as read.
    ///
    /// - Throws: ``WalletError/providerError(_:)`` when the lovelace does not fit a
    ///   `UInt64`, which no real set of UTxOs reaches.
    public static func of(_ utxos: [UTxO], rewards: UInt64? = nil) throws -> WalletBalance {
        let total = utxos.reduce(BigInt(0)) { $0 + $1.output.amount.coin }
        guard let lovelace = UInt64(exactly: total) else {
            throw WalletError.providerError("The UTxOs hold \(total) lovelace, more than a UInt64")
        }
        var assets = MultiAsset([:])
        for utxo in utxos {
            assets += utxo.output.amount.multiAsset
        }
        return WalletBalance(lovelace: lovelace, multiAsset: assets, rewards: rewards, utxoCount: utxos.count)
    }
}
