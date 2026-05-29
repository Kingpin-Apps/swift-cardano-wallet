import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

/// Helper: derive the test mnemonic's first payment + stake verification keys, return them
/// alongside the matching base address. Used by both wallet tests and stub setup.
private func vkeysAndAddress(network: Network = .preprod) async throws
-> (pVKey: PaymentVerificationKey, sVKey: StakeVerificationKey, address: Address)
{
    let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
    let account = Account(network: network)
    let pVKey = try await km.paymentVerificationKey(at: account.paymentPath())
    let sVKey = try await km.stakeVerificationKey(at: account.stakePath())
    let address = try await account.address(with: km)
    return (pVKey, sVKey, address)
}

@Suite("WatchOnlyWallet — read-only observation + unsigned-tx building")
struct WatchOnlyWalletTests {

    @Test func walletDerivesBaseAddressFromVKeys() async throws {
        let (pVKey, sVKey, expected) = try await vkeysAndAddress()
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == expected)
        #expect(try await wallet.changeAddress() == expected)
        #expect(wallet.kind == .watchOnly)
    }

    @Test func walletDerivesEnterpriseAddressWhenStakeOmitted() async throws {
        let (pVKey, _, _) = try await vkeysAndAddress()
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(paymentVerificationKey: pVKey),
            network: .preprod,
            chainContext: stub
        )
        let addr = try await wallet.receiveAddress()
        #expect(addr.stakingPart == nil)
    }

    @Test func rewardAddressThrowsWhenStakeOmitted() async throws {
        let (pVKey, _, _) = try await vkeysAndAddress()
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(paymentVerificationKey: pVKey),
            network: .preprod,
            chainContext: stub
        )
        do {
            _ = try await wallet.rewardAddress()
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func utxosAndBalanceQueryChain() async throws {
        let (pVKey, sVKey, address) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 7_500_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 7_500_000)
        #expect(balance.utxoCount == 1)
    }

    @Test func prepareSendBuildsUnsignedTransaction() async throws {
        let (pVKey, sVKey, address) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 100_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
        // Body has the expected output; no vkey witnesses yet.
        #expect(prepared.transaction.transactionBody.outputs.contains { $0.address == dest })
        #expect(prepared.transaction.transactionWitnessSet.vkeyWitnesses == nil)
    }

    // MARK: - Address-based construction (no vkeys)

    @Test func walletAcceptsBaseAddressDirectly() async throws {
        let (_, _, baseAddress) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: baseAddress, lovelace: 9_999_999)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try baseAddress.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            address: baseAddress,
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == baseAddress)
        #expect(wallet.kind == .watchOnly)

        let bal = try await wallet.balance()
        #expect(bal.lovelace == 9_999_999)

        // Reward address derivable from the vkey-hash staking part of the base address.
        let reward = try await wallet.rewardAddress()
        #expect(reward.paymentPart == nil)
        #expect(reward.stakingPart != nil)
    }

    @Test func walletAcceptsEnterpriseAddressWithoutStakingPart() async throws {
        // Build a vkey-only enterprise address (no staking part).
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let pVKey = try await km.paymentVerificationKey(at: Account(network: .preprod).paymentPath())
        let enterprise = try Address(
            paymentPart: .verificationKeyHash(try pVKey.hash()),
            network: Network.preprod.networkId
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            address: enterprise,
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == enterprise)
        // No staking part → rewardAddress() throws.
        do {
            _ = try await wallet.rewardAddress()
            Issue.record("Expected configurationMissing for enterprise reward address")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func walletAcceptsStakeOnlyAddress() async throws {
        // Construct a reward-only address (`stake1…` shape).
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let sVKey = try await km.stakeVerificationKey(at: Account(network: .preprod).stakePath())
        let rewardAddr = try Address(
            stakingPart: .verificationKeyHash(try sVKey.hash()),
            network: Network.preprod.networkId
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            address: rewardAddr,
            network: .preprod,
            chainContext: stub
        )
        // Reward address is the supplied address.
        #expect(try await wallet.rewardAddress() == rewardAddr)
        // No payment side: receive/utxos behave as expected.
        do {
            _ = try await wallet.receiveAddress()
            Issue.record("Expected configurationMissing for stake-only receive")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
        // utxos() short-circuits to empty (stake addresses don't hold UTxOs).
        #expect(try await wallet.utxos().isEmpty)
        let bal = try await wallet.balance()
        #expect(bal.lovelace == 0)
    }

    @Test func prepareSendThrowsOnStakeOnlyWallet() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let sVKey = try await km.stakeVerificationKey(at: Account(network: .preprod).stakePath())
        let rewardAddr = try Address(
            stakingPart: .verificationKeyHash(try sVKey.hash()),
            network: Network.preprod.networkId
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            address: rewardAddr,
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(with: km)
        do {
            _ = try await wallet.prepareSend(lovelace: 1_000_000, to: dest)
            Issue.record("Expected configurationMissing for stake-only prepareSend")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func walletEnumWatchOnlyAddressFactoryRoundTrips() async throws {
        let (_, _, baseAddress) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: baseAddress, lovelace: 4_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try baseAddress.toBech32(): [utxo]]
        )
        let wallet = try await Wallet.watchOnly(
            address: baseAddress,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .watchOnly)
        #expect(wallet.canSign == false)
        #expect(try await wallet.primaryAddress() == baseAddress)
        #expect(try await wallet.balance().lovelace == 4_000_000)
    }

    @Test func signingThroughPreparedTxThrowsWatchOnly() async throws {
        let (pVKey, sVKey, address) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 100_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
        do {
            _ = try await prepared.sign()
            Issue.record("Expected sign() to throw watchOnly")
        } catch let error as WalletError {
            if case .watchOnly = error { /* expected — wrapped via wrappingSigning? */ } else if case .signingFailed = error { /* also OK — gets wrapped */ } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}
