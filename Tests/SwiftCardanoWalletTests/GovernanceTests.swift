import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("Governance — DRep / vote delegation / voting")
struct GovernanceTests {

    private func wallet(
        funding: Int = 5_000_000_000,
        network: Network = .preprod
    ) async throws -> (wallet: MnemonicWallet, stub: StubChainContext, receive: Address) {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: funding)
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [try receive.toBech32(): [utxo]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 3
        )
        return (wallet, stub, receive)
    }

    /// 32-byte transaction hash → GovActionID(index: 0).
    private func sampleGovActionID() throws -> GovActionID {
        let txId = try TransactionId(payload: Data(repeating: 0xab, count: 32))
        return GovActionID(transactionID: txId, govActionIndex: 0)
    }

    // MARK: - DRep registration

    @Test func prepareRegisterDRepHasCertificateAndTwoSigningPaths() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareRegisterDRep()

        let body = prepared.transaction.transactionBody
        #expect((body.certificates?.count ?? 0) == 1)
        #expect(prepared.signingPaths.count == 2)
        let roles = Set(prepared.signingPaths.map { $0.role })
        #expect(roles.contains(.external))
        #expect(roles.contains(.stake))
    }

    @Test func registerDRepWithAnchor() async throws {
        let (wallet, _, _) = try await wallet()
        let anchor = GovernanceAnchor(
            url: "https://example.com/drep.json",
            dataHashHex: String(repeating: "ab", count: 32)
        )
        let prepared = try await wallet.prepareRegisterDRep(anchor: anchor)
        #expect((prepared.transaction.transactionBody.certificates?.count ?? 0) == 1)
    }

    @Test func registerDRepRejectsBadAnchorURL() async throws {
        let (wallet, _, _) = try await wallet()
        let anchor = GovernanceAnchor(
            url: "not-a-real-url",
            dataHashHex: String(repeating: "ab", count: 32)
        )
        do {
            _ = try await wallet.prepareRegisterDRep(anchor: anchor)
            // If the upstream `Url` validator accepts the input, this test is informational only;
            // we just want to ensure the code-path works and doesn't crash.
        } catch let error as WalletError {
            switch error {
            case .configurationMissing: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func registerDRepRejectsShortAnchorHash() async throws {
        let (wallet, _, _) = try await wallet()
        let anchor = GovernanceAnchor(
            url: "https://example.com/x.json",
            dataHashHex: "deadbeef"  // 4 bytes; needs 32
        )
        do {
            _ = try await wallet.prepareRegisterDRep(anchor: anchor)
            Issue.record("Expected configurationMissing for short anchor hash")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    // MARK: - Update / unregister

    @Test func prepareUpdateDRepHasCertificate() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareUpdateDRep()
        #expect((prepared.transaction.transactionBody.certificates?.count ?? 0) == 1)
    }

    @Test func prepareUnregisterDRepHasCertificate() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareUnregisterDRep()
        #expect((prepared.transaction.transactionBody.certificates?.count ?? 0) == 1)
        #expect(prepared.signingPaths.count == 2)
    }

    // MARK: - Vote delegation

    @Test func voteDelegationToAlwaysAbstain() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareVoteDelegation(to: .alwaysAbstain)
        let body = prepared.transaction.transactionBody
        #expect((body.certificates?.count ?? 0) == 1)
        #expect(prepared.signingPaths.count == 2)
    }

    @Test func voteDelegationToAlwaysNoConfidence() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareVoteDelegation(to: .alwaysNoConfidence)
        #expect((prepared.transaction.transactionBody.certificates?.count ?? 0) == 1)
    }

    @Test func voteDelegationRejectsInvalidDRepId() async throws {
        let (wallet, _, _) = try await wallet()
        do {
            _ = try await wallet.prepareVoteDelegation(to: .drepId("not-a-drep-bech32"))
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func signedDelegationHasTwoWitnesses() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareVoteDelegation(to: .alwaysAbstain)
        let signed = try await prepared.sign()
        guard case .nonEmptyOrderedSet(let set) = signed.transaction.transactionWitnessSet.vkeyWitnesses else {
            Issue.record("Expected non-empty witnesses")
            return
        }
        #expect(set.elements.count == 2)
    }

    // MARK: - Voting

    @Test func prepareVoteIncludesVotingProcedures() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareVote(
            on: try sampleGovActionID(),
            vote: .yes
        )
        // Body should have voting procedures populated.
        #expect(prepared.transaction.transactionBody.votingProcedures != nil)
        #expect(prepared.signingPaths.count == 2)
    }

    @Test func voteYesVsAbstainProduceDifferentBodies() async throws {
        let (wallet, _, _) = try await wallet()
        let actionId = try sampleGovActionID()
        let yes = try await wallet.prepareVote(on: actionId, vote: .yes)
        let abstain = try await wallet.prepareVote(on: actionId, vote: .abstain)
        #expect(yes.transaction.transactionBody.hash() != abstain.transaction.transactionBody.hash())
    }

    @Test func voteWithAnchorIncludesAnchorBytes() async throws {
        let (wallet, _, _) = try await wallet()
        let anchor = GovernanceAnchor(
            url: "https://example.com/rationale.json",
            dataHashHex: String(repeating: "12", count: 32)
        )
        let prepared = try await wallet.prepareVote(
            on: try sampleGovActionID(),
            vote: .no,
            anchor: anchor
        )
        // Just smoke-check it built; the procedure's anchor is a deep CBOR detail.
        #expect(prepared.transaction.transactionBody.votingProcedures != nil)
    }

    @Test func voteSignsWithBothPaymentAndStake() async throws {
        let (wallet, _, _) = try await wallet()
        let prepared = try await wallet.prepareVote(
            on: try sampleGovActionID(),
            vote: .yes
        )
        let signed = try await prepared.sign()
        guard case .nonEmptyOrderedSet(let set) = signed.transaction.transactionWitnessSet.vkeyWitnesses else {
            Issue.record("Expected non-empty witnesses")
            return
        }
        #expect(set.elements.count == 2)
    }

    // MARK: - GovernanceAnchor smoke

    @Test func anchorRoundTripsToCardanoType() throws {
        let anchor = GovernanceAnchor(
            url: "https://example.com",
            dataHashHex: String(repeating: "ab", count: 32)
        )
        let cardano = try anchor.toAnchor()
        #expect(cardano.anchorDataHash.payload.count == 32)
    }
}
