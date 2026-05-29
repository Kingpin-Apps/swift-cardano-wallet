import Testing
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("MnemonicWallet over a stub ChainContext")
struct MnemonicWalletTests {

    @Test func receiveAddressIsDeterministicAndOnNetwork() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let a = try await wallet.receiveAddress()
        let b = try await wallet.receiveAddress()
        #expect(a == b)
        #expect(try a.toBech32().hasPrefix("addr1"))
    }

    @Test func receiveAndChangeAddressDiffer() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let receive = try await wallet.receiveAddress()
        let change = try await wallet.changeAddress()
        #expect(receive != change)
    }

    @Test func emptyUtxoListGivesZeroBalance() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 0)
        #expect(balance.utxoCount == 0)
    }

    @Test func balanceSumsLovelaceAcrossUtxos() async throws {
        // Construct a wallet, capture its receive address, then build a stub that
        // returns three UTxOs at that exact address.
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { StubChainContext() })
        )
        let receive = try await probe.receiveAddress()
        let receiveBech32 = try receive.toBech32()

        let utxos = try [
            TestFixtures.makeUTxO(at: receive, lovelace: 1_500_000, index: 0),
            TestFixtures.makeUTxO(at: receive, lovelace:   500_000, index: 1),
            TestFixtures.makeUTxO(at: receive, lovelace: 8_000_000, index: 2),
        ]
        let stub = StubChainContext(utxos: [receiveBech32: utxos])

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )

        let fetched = try await wallet.utxos()
        let balance = try await wallet.balance()
        #expect(fetched.count == 3)
        #expect(balance.utxoCount == 3)
        #expect(balance.lovelace == 10_000_000)
    }

    @Test func mismatchedNetworkAndProviderThrows() async throws {
        // .blockfrost(network: .preprod) but wallet says .mainnet — should reject
        // before we attempt any network call.
        do {
            _ = try await MnemonicWallet(
                mnemonic: testMnemonic,
                network: .mainnet,
                provider: .blockfrost(projectId: "irrelevant", network: .preprod)
            )
            Issue.record("Expected configurationMissing error")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing:
                break
            default:
                Issue.record("Unexpected WalletError: \(error)")
            }
        }
    }

    @Test func customProviderSkipsNetworkSanityCheck() async throws {
        // .custom doesn't enforce network alignment — caller is trusted.
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let addr = try await wallet.receiveAddress()
        #expect(try addr.toBech32().hasPrefix("addr_test1"))
    }

    @Test func walletConformsToProtocol() async throws {
        let stub = StubChainContext()
        let wallet: any WalletProtocol = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .mnemonic)
        #expect(wallet.network == .mainnet)
        #expect(wallet.account.index == 0)
    }
}
