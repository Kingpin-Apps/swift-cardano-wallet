import Testing
import SwiftCardanoCore
@testable import SwiftCardanoWallet

@Test func walletConfigDefaults() {
    let config = WalletConfig(network: .mainnet)
    #expect(config.network == .mainnet)
    #expect(config.accountIndex == 0)
    #expect(config.addressGapLimit == 20)
    #expect(config.coinSelectionStrategy == .randomImproveMultiAsset)
    #expect(config.feeBufferPercent == 20)
}

@Test func walletKindIsCaseIterable() {
    #expect(WalletKind.allCases.count == 7)
    #expect(WalletKind.allCases.contains(.mnemonic))
    #expect(WalletKind.allCases.contains(.hardware))
}

@Test func walletErrorLocalizedDescription() {
    let err = WalletError.insufficientFunds(required: 5_000_000, available: 1_000_000)
    #expect(err.errorDescription?.contains("5000000") == true)
    #expect(err.errorDescription?.contains("1000000") == true)
}

@Test func walletErrorWatchOnly() {
    let err = WalletError.watchOnly
    #expect(err.errorDescription?.contains("watch-only") == true)
}
