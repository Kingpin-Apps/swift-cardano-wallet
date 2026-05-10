import Foundation
import SwiftCardanoCore

public struct WalletConfig: Sendable, Equatable {
    public var network: Network
    public var accountIndex: UInt32
    public var addressGapLimit: UInt32
    public var coinSelectionStrategy: CoinSelectionStrategy
    public var feeBufferPercent: UInt8

    public init(
        network: Network,
        accountIndex: UInt32 = 0,
        addressGapLimit: UInt32 = 20,
        coinSelectionStrategy: CoinSelectionStrategy = .randomImproveMultiAsset,
        feeBufferPercent: UInt8 = 20
    ) {
        self.network = network
        self.accountIndex = accountIndex
        self.addressGapLimit = addressGapLimit
        self.coinSelectionStrategy = coinSelectionStrategy
        self.feeBufferPercent = feeBufferPercent
    }
}

public enum CoinSelectionStrategy: Sendable, Equatable {
    case largestFirst
    case randomImproveMultiAsset
}
