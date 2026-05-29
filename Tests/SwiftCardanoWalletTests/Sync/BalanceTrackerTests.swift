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

@Suite("BalanceTracker gap-limit sweep")
struct BalanceTrackerTests {

    /// Build the wallet's first N receive addresses + their bech32 keys, for fixture seeding.
    private func deriveAddresses(roles: [DerivationPath.Role], indices: Range<UInt32>, network: Network)
    async throws -> [(role: DerivationPath.Role, index: UInt32, address: Address, bech32: String)]
    {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: network)
        var out: [(DerivationPath.Role, UInt32, Address, String)] = []
        for role in roles {
            for index in indices {
                let addr = try await acct.address(with: km, role: role, index: index)
                out.append((role, index, addr, try addr.toBech32()))
            }
        }
        return out
    }

    @Test func discoversFundsAcrossMultipleReceiveIndices() async throws {
        let network = Network.preprod
        let derived = try await deriveAddresses(
            roles: [.external],
            indices: 0..<3,
            network: network
        )

        // Funds at index 0 and index 2; index 1 is empty.
        var utxos: [String: [UTxO]] = [:]
        utxos[derived[0].bech32] = try [
            TestFixtures.makeUTxO(at: derived[0].address, lovelace: 1_000_000, index: 0)
        ]
        utxos[derived[2].bech32] = try [
            TestFixtures.makeUTxO(at: derived[2].address, lovelace: 4_000_000, index: 1),
            TestFixtures.makeUTxO(at: derived[2].address, lovelace: 2_000_000, index: 2),
        ]
        let stub = StubChainContext(networkId: network.networkId, utxos: utxos)

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 5
        )

        let allUtxos = try await wallet.utxos()
        #expect(allUtxos.count == 3)
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 7_000_000)
        #expect(balance.utxoCount == 3)
        #expect(balance.rewards == 0)
    }

    @Test func sweepCoversBothRoles() async throws {
        let network = Network.preprod
        let derived = try await deriveAddresses(
            roles: [.external, .change],
            indices: 0..<2,
            network: network
        )
        // 1 ADA at receive[0]; 3 ADA at change[1].
        let receive0 = derived.first { $0.role == .external && $0.index == 0 }!
        let change1 = derived.first { $0.role == .change && $0.index == 1 }!

        var utxos: [String: [UTxO]] = [:]
        utxos[receive0.bech32] = try [
            TestFixtures.makeUTxO(at: receive0.address, lovelace: 1_000_000, index: 0)
        ]
        utxos[change1.bech32] = try [
            TestFixtures.makeUTxO(at: change1.address, lovelace: 3_000_000, index: 0)
        ]
        let stub = StubChainContext(networkId: network.networkId, utxos: utxos)

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 5
        )
        let balance = try await wallet.balance()
        #expect(balance.utxoCount == 2)
        #expect(balance.lovelace == 4_000_000)
    }

    @Test func balanceIncludesRewards() async throws {
        let network = Network.preprod

        // Probe to learn the wallet's reward address.
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let rewardBech32 = try await probe.rewardAddress().toBech32()

        let stakeInfo = StakeAddressInfo(
            active: true,
            activeEpoch: 50,
            address: rewardBech32,
            rewardAccountBalance: 7_500_000
        )
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [:],
            stakeAddressInfo: [rewardBech32: [stakeInfo]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 3
        )
        let balance = try await wallet.balance()
        #expect(balance.rewards == 7_500_000)
        #expect(balance.lovelace == 0)
    }

    @Test func cachedAfterFirstRefresh() async throws {
        // Same balance() call twice should return the same UTxOs, and the stub should
        // see exactly 1 sweep × (gapLimit × 2 roles) queries.
        let network = Network.preprod
        let derived = try await deriveAddresses(
            roles: [.external],
            indices: 0..<1,
            network: network
        )
        let utxos: [String: [UTxO]] = try [
            derived[0].bech32: [
                TestFixtures.makeUTxO(at: derived[0].address, lovelace: 1_500_000, index: 0)
            ]
        ]
        let counter = QueryCountingStub(networkId: network.networkId, utxos: utxos)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { counter }),
            gapLimit: 3
        )
        _ = try await wallet.balance()
        let countAfterFirst = await counter.queryCount
        _ = try await wallet.balance()
        let countAfterSecond = await counter.queryCount
        #expect(countAfterSecond == countAfterFirst,
                "second balance() should be served from cache, got \(countAfterFirst) → \(countAfterSecond)")
    }

    @Test func explicitRefreshTriggersResweep() async throws {
        let network = Network.preprod
        let derived = try await deriveAddresses(
            roles: [.external],
            indices: 0..<1,
            network: network
        )
        let utxos: [String: [UTxO]] = try [
            derived[0].bech32: [
                TestFixtures.makeUTxO(at: derived[0].address, lovelace: 1_000_000, index: 0)
            ]
        ]
        let counter = QueryCountingStub(networkId: network.networkId, utxos: utxos)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { counter }),
            gapLimit: 3
        )
        _ = try await wallet.balance()
        let countAfterFirst = await counter.queryCount
        try await wallet.refresh()
        let countAfterRefresh = await counter.queryCount
        #expect(countAfterRefresh > countAfterFirst)
    }

    @Test func injectableUTxOStoreReceivesData() async throws {
        let network = Network.preprod
        let derived = try await deriveAddresses(
            roles: [.external],
            indices: 0..<1,
            network: network
        )
        let utxos: [String: [UTxO]] = try [
            derived[0].bech32: [
                TestFixtures.makeUTxO(at: derived[0].address, lovelace: 9_000_000, index: 0)
            ]
        ]
        let stub = StubChainContext(networkId: network.networkId, utxos: utxos)
        let store = InMemoryUTxOStore()

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            utxoStore: store,
            gapLimit: 3
        )
        _ = try await wallet.balance()

        // Address discovered + cached?
        let stored = try await store.utxos(for: derived[0].address)
        #expect(stored.count == 1)
        #expect(stored.first?.output.amount.coin == 9_000_000)
    }
}

// MARK: - Query-counting stub for cache-behaviour tests

final class QueryCountingStub: ChainContext, @unchecked Sendable {
    let name: String = "QueryCountingStub"
    let type: ContextType = .offline
    let networkId: NetworkId

    private let inner: StubChainContext
    private let counter = QueryCounter()

    var queryCount: Int { get async { await counter.value } }

    init(networkId: NetworkId, utxos: [String: [UTxO]] = [:]) {
        self.networkId = networkId
        self.inner = StubChainContext(networkId: networkId, utxos: utxos)
    }

    func protocolParameters() async throws -> ProtocolParameters {
        try await inner.protocolParameters()
    }

    func genesisParameters() async throws -> GenesisParameters {
        try await inner.genesisParameters()
    }

    func era() async throws -> Era? { try await inner.era() }
    func epoch() async throws -> Int { try await inner.epoch() }
    func lastBlockSlot() async throws -> Int { try await inner.lastBlockSlot() }

    func chainTip() async throws -> ChainTip { try await inner.chainTip() }

    func utxos(address: Address) async throws -> [UTxO] {
        await counter.increment()
        return try await inner.utxos(address: address)
    }

    func submitTxCBOR(cbor: Data) async throws -> String {
        try await inner.submitTxCBOR(cbor: cbor)
    }

    func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        try await inner.stakeAddressInfo(address: address)
    }
}

private actor QueryCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
