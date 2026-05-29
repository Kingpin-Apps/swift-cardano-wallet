import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

/// A real testnet pool id, used only as a syntactically valid bech32 input. Never reaches a real chain.
private let samplePoolId = "pool1qqa8tkycj4zck4sy7n8mqr22x5g7tvm8hnp9st95wmuvvtw28th"

@Suite("MnemonicWallet stake operations")
struct StakeTests {

    /// Build a wallet whose receive address holds enough lovelace to cover all stake-tx fees + deposit.
    private func wallet(
        funding: Int64 = 5_000_000_000,
        stakeInfo: [StakeAddressInfo]? = nil,
        network: Network = .preprod
    ) async throws -> (wallet: MnemonicWallet, stub: StubChainContext, receive: Address, reward: Address) {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        let receiveBech32 = try receive.toBech32()
        let reward = try await probe.rewardAddress()
        let rewardBech32 = try reward.toBech32()

        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: funding)
        var stakeMap: [String: [StakeAddressInfo]] = [:]
        if let stakeInfo {
            stakeMap[rewardBech32] = stakeInfo
        }

        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [receiveBech32: [utxo]],
            stakeAddressInfo: stakeMap
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub })
        )
        return (wallet, stub, receive, reward)
    }

    // MARK: - Registration

    @Test func prepareStakeRegistrationProducesValidUnsignedTx() async throws {
        let (wallet, _, _, _) = try await wallet()
        let prepared = try await wallet.prepareStakeRegistration()

        let body = prepared.transaction.transactionBody
        #expect(body.inputs.count >= 1)
        #expect((body.certificates?.count ?? 0) == 1)
        // Conway-era: registration requires both payment (deposit) and stake (credential ownership).
        #expect(prepared.signingPaths.count == 2)
        let roles = Set(prepared.signingPaths.map { $0.role })
        #expect(roles.contains(.external))
        #expect(roles.contains(.stake))
    }

    @Test func registerStakeOneShotDispatchesToChain() async throws {
        let (wallet, stub, _, _) = try await wallet()
        let txId = try await wallet.registerStake()
        #expect(txId.hasPrefix("stubtx-"))
        #expect(stub.submittedCBOR.count == 1)
    }

    @Test func registerStakeRejectsAlreadyRegisteredAccount() async throws {
        // Pre-seed the stub with an active stake registration so the txbuilder's
        // uniqueness check fires.
        let already = StakeAddressInfo(
            active: true,
            activeEpoch: 50,
            address: "stake_test1...",
            rewardAccountBalance: 0
        )
        let (wallet, _, _, _) = try await wallet(stakeInfo: [already])
        do {
            _ = try await wallet.prepareStakeRegistration()
            Issue.record("Expected validationFailed")
        } catch let error as WalletError {
            switch error {
            case .validationFailed: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    // MARK: - Delegation

    /// The delegation shortcut's chain check requires the stake address to already be registered.
    private func registeredStakeInfo(rewards: Int64 = 0) -> StakeAddressInfo {
        StakeAddressInfo(
            active: true,
            activeEpoch: 50,
            address: "stake_test1...",
            rewardAccountBalance: rewards
        )
    }

    @Test func prepareDelegationIncludesStakeAndPaymentSigningPaths() async throws {
        let (wallet, _, _, _) = try await wallet(stakeInfo: [registeredStakeInfo()])
        let prepared = try await wallet.prepareStakeDelegation(toPool: samplePoolId)
        #expect(prepared.signingPaths.count == 2)
        let roles = Set(prepared.signingPaths.map { $0.role })
        #expect(roles.contains(.external))
        #expect(roles.contains(.stake))
    }

    @Test func delegationSignAttachesTwoWitnesses() async throws {
        let (wallet, _, _, _) = try await wallet(stakeInfo: [registeredStakeInfo()])
        let prepared = try await wallet.prepareStakeDelegation(toPool: samplePoolId)
        let signed = try await prepared.sign()

        let witnesses = signed.transaction.transactionWitnessSet.vkeyWitnesses
        guard case .nonEmptyOrderedSet(let set) = witnesses else {
            Issue.record("vkeyWitnesses missing or wrong shape")
            return
        }
        #expect(set.elements.count == 2)
    }

    @Test func invalidPoolIdIsRejectedEarly() async throws {
        let (wallet, _, _, _) = try await wallet(stakeInfo: [registeredStakeInfo()])
        do {
            _ = try await wallet.prepareStakeDelegation(toPool: "not-a-pool")
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    // MARK: - Register + delegate

    @Test func prepareRegisterAndDelegateBundlesTwoCertificates() async throws {
        let (wallet, _, _, _) = try await wallet()
        let prepared = try await wallet.prepareStakeRegistrationAndDelegation(toPool: samplePoolId)
        let body = prepared.transaction.transactionBody
        #expect((body.certificates?.count ?? 0) >= 1)
        #expect(prepared.signingPaths.count == 2)
    }

    // MARK: - Withdrawals

    @Test func claimAllRewardsReturnsNilWhenNoRewards() async throws {
        let info = StakeAddressInfo(
            active: true,
            address: "stake_test1...",
            rewardAccountBalance: 0
        )
        let (wallet, _, _, _) = try await wallet(stakeInfo: [info])
        let txId = try await wallet.claimAllRewards()
        #expect(txId == nil)
    }

    @Test func claimAllRewardsReturnsNilWhenStakeAccountUnknown() async throws {
        let (wallet, _, _, _) = try await wallet(stakeInfo: nil)
        let txId = try await wallet.claimAllRewards()
        #expect(txId == nil)
    }

    @Test func prepareWithdrawalProducesTwoSigningPaths() async throws {
        let (wallet, _, _, _) = try await wallet(stakeInfo: [registeredStakeInfo(rewards: 5_000_000)])
        let prepared = try await wallet.prepareStakeWithdrawal()
        #expect(prepared.signingPaths.count == 2)
    }

    @Test func claimAllRewardsSubmitsWhenRewardsPresent() async throws {
        let (wallet, stub, _, _) = try await wallet(stakeInfo: [registeredStakeInfo(rewards: 5_000_000)])
        let txId = try await wallet.claimAllRewards()
        #expect(txId != nil)
        #expect(stub.submittedCBOR.count == 1)
    }

    // MARK: - Deregistration

    @Test func prepareDeregistrationProducesTwoSigningPaths() async throws {
        let (wallet, _, _, _) = try await wallet(stakeInfo: [registeredStakeInfo()])
        let prepared = try await wallet.prepareStakeDeregistration()
        #expect(prepared.signingPaths.count == 2)
        #expect((prepared.transaction.transactionBody.certificates?.count ?? 0) == 1)
    }
}
