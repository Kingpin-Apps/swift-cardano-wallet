import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("MnemonicWallet send (build + sign + submit)")
struct SendTests {

    /// Helper: build a wallet whose receive address has a 10 ADA UTxO.
    private func wallet(withFunding lovelace: Int64, network: Network = .preprod) async throws
    -> (wallet: MnemonicWallet, stub: StubChainContext, receive: Address)
    {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        let receiveBech32 = try receive.toBech32()
        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: lovelace)
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [receiveBech32: [utxo]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub })
        )
        return (wallet, stub, receive)
    }

    @Test func prepareSendBuildsValidUnsignedTx() async throws {
        let (wallet, _, _) = try await wallet(withFunding: 10_000_000)
        let recipient = try await wallet.changeAddress() // any address, just for the test

        let prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)

        // Body has at least one input and one output.
        let body = prepared.transaction.transactionBody
        #expect(body.inputs.count >= 1)
        #expect(body.outputs.count >= 1)

        // Some output goes to the recipient with at least 2 ADA.
        let recipientOutput = body.outputs.first { $0.address == recipient }
        #expect(recipientOutput != nil)
        #expect(recipientOutput?.amount.coin == 2_000_000)

        // Witness set is empty until we sign.
        #expect(prepared.transaction.transactionWitnessSet.vkeyWitnesses == nil)

        // CBOR exports successfully.
        #expect(prepared.exportCBOR().isEmpty == false)
    }

    @Test func signAttachesExactlyOneVkeyWitness() async throws {
        let (wallet, _, _) = try await wallet(withFunding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let prepared = try await wallet.prepareSend(lovelace: 1_500_000, to: recipient)
        let signed = try await prepared.sign()

        let witnesses = signed.transaction.transactionWitnessSet.vkeyWitnesses
        #expect(witnesses != nil)
        if case .nonEmptyOrderedSet(let set) = witnesses {
            #expect(set.elements.count == 1)
        } else {
            Issue.record("vkeyWitnesses should be nonEmptyOrderedSet, got \(String(describing: witnesses))")
        }
    }

    @Test func signedTxHasIdAndDifferentCBORThanUnsigned() async throws {
        let (wallet, _, _) = try await wallet(withFunding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let prepared = try await wallet.prepareSend(lovelace: 1_500_000, to: recipient)
        let unsignedCBOR = prepared.exportCBOR()

        let signed = try await prepared.sign()
        #expect(signed.id != nil)
        #expect(signed.exportCBOR() != unsignedCBOR)
    }

    @Test func submitDispatchesToChainContext() async throws {
        let (wallet, stub, _) = try await wallet(withFunding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let txId = try await wallet.send(lovelace: 1_500_000, to: recipient)
        #expect(txId.hasPrefix("stubtx-"))
        #expect(stub.submittedCBOR.count == 1)
    }

    @Test func sendingMoreThanBalanceThrowsInsufficientFunds() async throws {
        let (wallet, _, _) = try await wallet(withFunding: 1_000_000)
        let recipient = try await wallet.changeAddress()
        do {
            _ = try await wallet.prepareSend(lovelace: 5_000_000, to: recipient)
            Issue.record("Expected insufficientFunds")
        } catch let error as WalletError {
            switch error {
            case .insufficientFunds:
                break
            default:
                Issue.record("Unexpected WalletError: \(error)")
            }
        }
    }

    @Test func sendingFromEmptyWalletThrowsInsufficientFunds() async throws {
        let stub = StubChainContext(networkId: NetworkId.testnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let recipient = try await wallet.changeAddress()
        do {
            _ = try await wallet.prepareSend(lovelace: 1_500_000, to: recipient)
            Issue.record("Expected insufficientFunds")
        } catch let error as WalletError {
            switch error {
            case .insufficientFunds(_, let available):
                #expect(available == 0)
            default:
                Issue.record("Unexpected WalletError: \(error)")
            }
        }
    }

    // MARK: - Multi-address signing

    /// Build a wallet that has UTxOs at *two* derived addresses (external 0 and change 0)
    /// with funding at each, so coin selection is forced to pull from both.
    private func multiAddressWallet(
        externalLovelace: Int64 = 4_000_000,
        changeLovelace: Int64 = 4_000_000,
        network: Network = .preprod
    ) async throws -> (wallet: MnemonicWallet, stub: StubChainContext, external: Address, change: Address) {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let external = try await probe.receiveAddress()
        let change = try await probe.changeAddress()

        let extUTxO = try TestFixtures.makeUTxO(at: external, lovelace: externalLovelace, index: 0)
        let chgUTxO = try TestFixtures.makeUTxO(at: change, lovelace: changeLovelace, index: 1)
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [
                try external.toBech32(): [extUTxO],
                try change.toBech32(): [chgUTxO],
            ]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub })
        )
        return (wallet, stub, external, change)
    }

    @Test func signingPathsCoverEveryDistinctInputAddress() async throws {
        // Send 6 ADA — neither single UTxO is enough on its own, so coin selection has to
        // consume both, which means the signed tx must carry two distinct vkey witnesses
        // (one for the external-0 key, one for the change-0 key).
        let (wallet, _, external, change) = try await multiAddressWallet()
        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let prepared = try await wallet.prepareSend(lovelace: 6_000_000, to: dest)

        // The signing-paths set should contain two paths: external-0 and change-0.
        let roles = Set(prepared.signingPaths.map { $0.role })
        #expect(roles == [.external, .change])

        // Sign and verify two distinct witnesses landed in the witness set.
        let signed = try await prepared.sign()
        guard case .nonEmptyOrderedSet(let set) = signed.transaction.transactionWitnessSet.vkeyWitnesses else {
            Issue.record("Expected non-empty witnesses on signed tx")
            return
        }
        #expect(set.elements.count == 2)

        // Both witness vkeys should hash to one of the two contributing addresses' payment
        // credentials.
        guard
            case .verificationKeyHash(let externalKeyHash) = external.paymentPart,
            case .verificationKeyHash(let changeKeyHash) = change.paymentPart
        else {
            Issue.record("Test fixture addresses must have vkey-hash payment parts")
            return
        }
        let observedHashes = Set(set.elements.compactMap { witness -> VerificationKeyHash? in
            switch witness.vkey {
            case .verificationKey(let v): return try? v.hash()
            case .extendedVerificationKey(let v):
                let result: (VerificationKeyHash, VerificationKey)? = try? v.hash()
                return result?.0
            }
        })
        #expect(observedHashes.contains(externalKeyHash))
        #expect(observedHashes.contains(changeKeyHash))
    }

    @Test func singleAddressFundingStillProducesOneWitness() async throws {
        // Regression: when only one address contributes inputs, signingPaths has exactly
        // one entry (no duplicates from over-eager path resolution).
        let (wallet, _, _) = try await wallet(withFunding: 10_000_000)
        let prepared = try await wallet.prepareSend(
            lovelace: 1_500_000,
            to: try await wallet.changeAddress()
        )
        #expect(prepared.signingPaths.count == 1)
        #expect(prepared.signingPaths.first?.role == .external)
    }

    @Test func cborRoundTripPreservesSignature() async throws {
        let (wallet, _, _) = try await wallet(withFunding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let signed = try await wallet.prepareSend(lovelace: 1_500_000, to: recipient).sign()

        let cbor = signed.exportCBOR()
        let parsed = Transaction(payload: cbor, type: nil, description: nil)

        // Same body hash before and after CBOR round-trip — proves witnesses match the body.
        #expect(parsed.transactionBody.hash() == signed.transaction.transactionBody.hash())
        if case .nonEmptyOrderedSet(let parsedSet) = parsed.transactionWitnessSet.vkeyWitnesses {
            #expect(parsedSet.elements.count == 1)
        } else {
            Issue.record("Round-tripped tx is missing its witness")
        }
    }
}
