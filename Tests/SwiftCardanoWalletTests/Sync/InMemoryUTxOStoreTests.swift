import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("InMemoryUTxOStore round-trip")
struct InMemoryUTxOStoreTests {

    @Test func upsertAndReadBack() async throws {
        let store = InMemoryUTxOStore()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)

        let utxos = try [
            TestFixtures.makeUTxO(at: addr, lovelace: 1_000_000, index: 0),
            TestFixtures.makeUTxO(at: addr, lovelace: 2_000_000, index: 1),
        ]
        try await store.upsert(utxos, for: addr)

        let readBack = try await store.utxos(for: addr)
        #expect(readBack.count == 2)

        let allAddresses = try await store.allAddresses()
        #expect(allAddresses.count == 1)
        #expect(allAddresses.first == addr)
    }

    @Test func upsertReplacesNotMerges() async throws {
        let store = InMemoryUTxOStore()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)

        try await store.upsert(
            [TestFixtures.makeUTxO(at: addr, lovelace: 1_000_000, index: 0)],
            for: addr
        )
        try await store.upsert(
            [TestFixtures.makeUTxO(at: addr, lovelace: 5_000_000, index: 1)],
            for: addr
        )
        let readBack = try await store.utxos(for: addr)
        #expect(readBack.count == 1)
        #expect(readBack.first?.output.amount.coin == 5_000_000)
    }

    @Test func clearWipesEverything() async throws {
        let store = InMemoryUTxOStore()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)

        try await store.upsert(
            [TestFixtures.makeUTxO(at: addr, lovelace: 1_000_000, index: 0)],
            for: addr
        )
        try await store.clear()
        #expect(try await store.allAddresses().isEmpty)
        #expect(try await store.utxos(for: addr).isEmpty)
    }

    @Test func unknownAddressReturnsEmpty() async throws {
        let store = InMemoryUTxOStore()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)
        let utxos = try await store.utxos(for: addr)
        #expect(utxos.isEmpty)
    }
}
