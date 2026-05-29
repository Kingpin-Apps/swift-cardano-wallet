import Foundation
import SwiftCardanoCore

/// Aggregate balance over a wallet's tracked UTxOs.
///
/// `lovelace` is the native ADA amount (1 ADA = 1_000_000 lovelace). `multiAsset` aggregates
/// every native token currently held. `rewards` is the unwithdrawn stake-account balance,
/// reported by `ChainContext.stakeAddressInfo` — `0` if the stake address isn't registered.
/// `utxoCount` is the number of UTxOs that contributed to the totals.
public struct WalletBalance: Sendable, Equatable {
    public let lovelace: Int64
    public let multiAsset: MultiAsset
    public let rewards: Int64
    public let utxoCount: Int

    public init(
        lovelace: Int64,
        multiAsset: MultiAsset = MultiAsset([:]),
        rewards: Int64 = 0,
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
}
