import Testing
import Foundation
import SwiftCardanoCore
@testable import SwiftCardanoWallet

@Suite("WalletBalance")
struct WalletBalanceTests {

    @Test func zeroIsAllZeros() {
        let z = WalletBalance.zero
        #expect(z.lovelace == 0)
        #expect(z.rewards == 0)
        #expect(z.utxoCount == 0)
        #expect(z.multiAsset == MultiAsset([:]))
    }

    @Test func equatableHonorsAllFields() {
        let a = WalletBalance(lovelace: 1_000_000, rewards: 0, utxoCount: 1)
        let b = WalletBalance(lovelace: 1_000_000, rewards: 0, utxoCount: 1)
        let c = WalletBalance(lovelace: 1_000_000, rewards: 0, utxoCount: 2)  // different count
        let d = WalletBalance(lovelace: 2_000_000, rewards: 0, utxoCount: 1)  // different lovelace
        let e = WalletBalance(lovelace: 1_000_000, rewards: 10, utxoCount: 1) // different rewards
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a != e)
    }

    @Test func defaultMultiAssetIsEmpty() {
        let b = WalletBalance(lovelace: 100, utxoCount: 1)
        #expect(b.multiAsset == MultiAsset([:]))
        #expect(b.rewards == 0)
    }

    @Test func canCarryMultiAsset() {
        let pid = ScriptHash(payload: Data(repeating: 0xab, count: 28))
        let name = AssetName(from: "Tok")
        let assets = MultiAsset([pid: Asset([name: 42])])
        let b = WalletBalance(
            lovelace: 5_000_000,
            multiAsset: assets,
            rewards: 100,
            utxoCount: 1
        )
        #expect(b.multiAsset == assets)
        #expect(b.rewards == 100)
    }
}
