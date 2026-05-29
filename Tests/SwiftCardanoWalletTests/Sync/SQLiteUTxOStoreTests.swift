#if WALLET_HAS_SQLITE

import Testing
import Foundation
import SwiftCardanoCore
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("SQLiteUTxOStore round-trip")
struct SQLiteUTxOStoreTests {

    @Test func inMemoryUpsertAndReadBack() async throws {
        let store = try await SQLiteUTxOStore.openInMemory()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)

        let utxos = try [
            TestFixtures.makeUTxO(at: addr, lovelace: 1_000_000, index: 0),
            TestFixtures.makeUTxO(at: addr, lovelace: 2_500_000, index: 1),
        ]
        try await store.upsert(utxos, for: addr)

        let readBack = try await store.utxos(for: addr)
        #expect(readBack.count == 2)
        let totalLovelace = readBack.reduce(0) { $0 + $1.output.amount.coin }
        #expect(totalLovelace == 3_500_000)
    }

    @Test func upsertReplacesNotMerges() async throws {
        let store = try await SQLiteUTxOStore.openInMemory()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)

        try await store.upsert(
            [TestFixtures.makeUTxO(at: addr, lovelace: 1_000_000, index: 0)],
            for: addr
        )
        try await store.upsert(
            [TestFixtures.makeUTxO(at: addr, lovelace: 9_000_000, index: 1)],
            for: addr
        )
        let readBack = try await store.utxos(for: addr)
        #expect(readBack.count == 1)
        #expect(readBack.first?.output.amount.coin == 9_000_000)
    }

    @Test func multipleAddressesCoexist() async throws {
        let store = try await SQLiteUTxOStore.openInMemory()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let receive = try await acct.address(with: mk)
        let change = try await acct.address(with: mk, role: .change)

        try await store.upsert(
            [TestFixtures.makeUTxO(at: receive, lovelace: 1_000_000, index: 0)],
            for: receive
        )
        try await store.upsert(
            [TestFixtures.makeUTxO(at: change, lovelace: 2_000_000, index: 0)],
            for: change
        )

        let listed = try await store.allAddresses()
        #expect(listed.count == 2)
        #expect(listed.contains(receive))
        #expect(listed.contains(change))
    }

    @Test func clearWipesEverything() async throws {
        let store = try await SQLiteUTxOStore.openInMemory()
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
        let store = try await SQLiteUTxOStore.openInMemory()
        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)
        let utxos = try await store.utxos(for: addr)
        #expect(utxos.isEmpty)
    }

    @Test func filePersistenceSurvivesReopen() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("utxos.sqlite").path

        let mk = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .mainnet)
        let addr = try await acct.address(with: mk)
        let utxo = try TestFixtures.makeUTxO(at: addr, lovelace: 7_777_777, index: 0)

        // Write through one connection.
        do {
            let store = try await SQLiteUTxOStore.open(filePath: path)
            try await store.upsert([utxo], for: addr)
        }

        // Reopen and read — data should still be there.
        let store2 = try await SQLiteUTxOStore.open(filePath: path)
        let readBack = try await store2.utxos(for: addr)
        #expect(readBack.count == 1)
        #expect(readBack.first?.output.amount.coin == 7_777_777)
    }

    @Test func walletAcceptsSqliteStoreAsInjection() async throws {
        // Probe the wallet's first receive address.
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let receive = try await probe.receiveAddress()
        let receiveBech32 = try receive.toBech32()

        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: 10_000_000, index: 0)
        let stub = StubChainContext(networkId: .testnet, utxos: [receiveBech32: [utxo]])
        let store = try await SQLiteUTxOStore.openInMemory()

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub }),
            utxoStore: store,
            gapLimit: 3
        )

        let balance = try await wallet.balance()
        #expect(balance.lovelace == 10_000_000)

        // The store should now contain the swept UTxO durably.
        let stored = try await store.utxos(for: receive)
        #expect(stored.count == 1)
    }
}

#endif
