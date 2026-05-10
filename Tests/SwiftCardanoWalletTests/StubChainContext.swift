import Foundation
import Testing
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoUPLC

/// Test-only `ChainContext` implementation for unit tests. Loads protocol parameters from the
/// bundled `protocol-parameters.json` fixture (copied from `swift-cardano-txbuilder`) so that
/// `TxBuilder.build()` has the data it needs for fee math.
final class StubChainContext: ChainContext, @unchecked Sendable {
    let name: String = "Stub"
    let type: ContextType = .offline
    let networkId: NetworkId

    private let utxosByAddress: [String: [UTxO]]
    private let stakeInfoByAddress: [String: [StakeAddressInfo]]
    private let _protocolParameters: ProtocolParameters
    private(set) var submittedCBOR: [Data] = []

    init(
        networkId: NetworkId = .testnet,
        utxos: [String: [UTxO]] = [:],
        stakeAddressInfo: [String: [StakeAddressInfo]] = [:],
        protocolParameters: ProtocolParameters? = nil
    ) {
        self.networkId = networkId
        self.utxosByAddress = utxos
        self.stakeInfoByAddress = stakeAddressInfo
        self._protocolParameters = protocolParameters ?? Self.loadFixtureProtocolParameters()
    }

    private static func loadFixtureProtocolParameters() -> ProtocolParameters {
        guard let url = Bundle.module.url(forResource: "protocol-parameters", withExtension: "json", subdirectory: "data") else {
            fatalError("StubChainContext: bundled protocol-parameters.json fixture not found")
        }
        do {
            return try ProtocolParameters.load(from: url.path)
        } catch {
            fatalError("StubChainContext: failed to load protocol parameters: \(error)")
        }
    }

    func protocolParameters() async throws -> ProtocolParameters {
        _protocolParameters
    }

    func genesisParameters() async throws -> GenesisParameters {
        GenesisParameters(
            activeSlotsCoefficient: 0.05,
            epochLength: 432_000,
            maxKesEvolutions: 62,
            maxLovelaceSupply: 45_000_000_000_000_000,
            networkId: "testnet",
            networkMagic: 1,
            securityParam: 2160,
            slotLength: 1,
            slotsPerKesPeriod: 129_600,
            systemStart: ISO8601DateFormatter().date(from: "2022-06-01T00:00:00Z")!,
            updateQuorum: 5
        )
    }

    func era() async throws -> Era? { .conway }
    func epoch() async throws -> Int { 100 }
    func lastBlockSlot() async throws -> Int { 50_000_000 }

    func chainTip() async throws -> ChainTip {
        ChainTip(
            block: nil,
            epoch: 100,
            era: Era.conway.rawValue,
            hash: nil,
            slot: 50_000_000,
            slotInEpoch: nil,
            slotsToEpochEnd: nil,
            syncProgress: nil
        )
    }

    func utxos(address: Address) async throws -> [UTxO] {
        let key = (try? address.toBech32()) ?? address.description
        return utxosByAddress[key] ?? []
    }

    func submitTxCBOR(cbor: Data) async throws -> String {
        submittedCBOR.append(cbor)
        // Return a deterministic txId derived from the cbor length so tests can assert on it.
        return String(format: "stubtx-%d", cbor.count)
    }

    func stakeAddressInfo(address: Address) async throws -> [StakeAddressInfo] {
        let key = (try? address.toBech32()) ?? address.description
        return stakeInfoByAddress[key] ?? []
    }
}

// MARK: - Test fixture helpers

enum TestFixtures {
    static let dummyTxId = String(repeating: "ab", count: 32)

    static func makeUTxO(at address: Address, lovelace: Int, index: UInt16 = 0) throws -> UTxO {
        let txInput = try TransactionInput(from: dummyTxId, index: index)
        let txOutput = TransactionOutput(
            address: address,
            amount: Value(coin: lovelace)
        )
        return UTxO(input: txInput, output: txOutput)
    }
}
