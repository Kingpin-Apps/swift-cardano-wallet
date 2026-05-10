import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoCIPs
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("MnemonicWallet conforms to CIP30Provider")
struct CIP30Tests {

    private func wallet(funding: Int = 10_000_000, network: Network = .preprod)
    async throws -> (wallet: MnemonicWallet, stub: StubChainContext, receive: Address)
    {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        let receiveBech32 = try receive.toBech32()
        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: funding)
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [receiveBech32: [utxo]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 3
        )
        return (wallet, stub, receive)
    }

    @Test func networkIdMatchesNetwork() async throws {
        let mainnet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { StubChainContext(networkId: .mainnet) })
        )
        #expect(try await mainnet.getNetworkId() == 1)

        let testnet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        #expect(try await testnet.getNetworkId() == 0)
    }

    @Test func getUtxosReturnsCBOREncodedSet() async throws {
        let (wallet, _, _) = try await wallet()
        let utxosCBOR = try await wallet.getUtxos(amount: nil, paginate: nil)
        #expect(utxosCBOR != nil)
        #expect(utxosCBOR?.count == 1)
        // Each entry must round-trip back into a UTxO.
        if let cbor = utxosCBOR?.first {
            let parsed = try UTxO.fromCBOR(data: cbor)
            #expect(parsed.output.amount.coin == 10_000_000)
        }
    }

    @Test func getUtxosReturnsNilWhenEmpty() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub }),
            gapLimit: 3
        )
        let utxosCBOR = try await wallet.getUtxos(amount: nil, paginate: nil)
        #expect(utxosCBOR == nil)
    }

    @Test func getBalanceEncodesValueAsCBOR() async throws {
        let (wallet, _, _) = try await wallet(funding: 7_777_777)
        let balanceCBOR = try await wallet.getBalance()
        let parsed = try Value.fromCBOR(data: balanceCBOR)
        #expect(parsed.coin == 7_777_777)
    }

    @Test func getChangeAddressRoundTrips() async throws {
        let (wallet, _, _) = try await wallet()
        let cbor = try await wallet.getChangeAddress()
        let parsed = try Address.fromCBOR(data: cbor)
        let expected = try await wallet.changeAddress()
        #expect(parsed == expected)
    }

    @Test func getRewardAddressesProducesOneEntry() async throws {
        let (wallet, _, _) = try await wallet()
        let cbor = try await wallet.getRewardAddresses()
        #expect(cbor.count == 1)
        let parsed = try Address.fromCBOR(data: cbor[0])
        let expected = try await wallet.rewardAddress()
        #expect(parsed == expected)
    }

    @Test func getUsedAddressesIncludesFundedReceive() async throws {
        let (wallet, _, receive) = try await wallet()
        let cbor = try await wallet.getUsedAddresses(paginate: nil)
        let parsed = try cbor.map { try Address.fromCBOR(data: $0) }
        #expect(parsed.contains(receive))
    }

    @Test func getUnusedAddressesAtIndexZeroAreReceiveAndChange() async throws {
        let (wallet, _, _) = try await wallet()
        let cbor = try await wallet.getUnusedAddresses()
        #expect(cbor.count == 2)
        let parsed = try cbor.map { try Address.fromCBOR(data: $0) }
        let receive = try await wallet.receiveAddress()
        let change = try await wallet.changeAddress()
        #expect(parsed.contains(receive))
        #expect(parsed.contains(change))
    }

    @Test func paginationSlicesAddresses() async throws {
        // Seed UTxOs at multiple receive addresses so getUsedAddresses returns >= 2 entries.
        let network = Network.preprod
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let acct = Account(network: network)
        let probeKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        var utxos: [String: [UTxO]] = [:]
        for i: UInt32 in 0..<3 {
            let addr = try await acct.address(with: probeKM, role: .external, index: i)
            utxos[try addr.toBech32()] = try [
                TestFixtures.makeUTxO(at: addr, lovelace: 1_000_000, index: UInt16(i))
            ]
        }
        _ = probe
        let stub = StubChainContext(networkId: network.networkId, utxos: utxos)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 5
        )
        let page0 = try await wallet.getUsedAddresses(paginate: Paginate(page: 0, limit: 2))
        #expect(page0.count == 2)

        let allUsed = try await wallet.getUsedAddresses(paginate: nil)
        #expect(allUsed.count >= 3)
    }

    @Test func signTxReturnsWitnessSetWithOneVKeyWitness() async throws {
        // Build any tx via prepareSend and ask CIP-30 to sign its CBOR.
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)
        let txCBOR = prepared.exportCBOR()

        let witnessSetCBOR = try await wallet.signTx(txCBOR, partialSign: false)
        let witnessSet = try TransactionWitnessSet.fromCBOR(data: witnessSetCBOR)
        if case .nonEmptyOrderedSet(let set) = witnessSet.vkeyWitnesses {
            #expect(set.elements.count == 1)
        } else {
            Issue.record("Expected nonEmptyOrderedSet, got \(String(describing: witnessSet.vkeyWitnesses))")
        }
    }

    @Test func submitTxDispatchesToChainContext() async throws {
        let (wallet, stub, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let signed = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient).sign()
        let txId = try await wallet.submitTx(signed.exportCBOR())
        #expect(txId.hasPrefix("stubtx-"))
        #expect(stub.submittedCBOR.count == 1)
    }

    @Test func signDataProducesHexSignatureAndKey() async throws {
        let (wallet, _, _) = try await wallet()
        let receive = try await wallet.receiveAddress()
        let bech32 = try receive.toBech32()
        let result = try await wallet.signData(
            address: bech32,
            payload: Data("hello cardano".utf8)
        )
        #expect(!result.signature.isEmpty)
        // attachCoseKey: true → key field is populated.
        #expect(!result.key.isEmpty)
    }

    @Test func signDataAcceptsStakeAddress() async throws {
        let (wallet, _, _) = try await wallet()
        let stakeBech32 = try await wallet.rewardAddress().toBech32()
        let result = try await wallet.signData(
            address: stakeBech32,
            payload: Data("stake msg".utf8)
        )
        #expect(!result.signature.isEmpty)
    }
}
