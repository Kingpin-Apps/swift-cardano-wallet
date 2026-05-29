import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

/// One cosigner. Holds the key manager + the path so signing is straightforward.
private struct Cosigner {
    let account: Account
    let keyManager: MnemonicKeyManager
    let path: DerivationPath
    let keyHash: VerificationKeyHash
    let signingKey: SigningKeyType
}

@Suite("MultisigPolicy + MultisigWallet end-to-end")
struct MultisigTests {

    /// Three cosigners derived from the same mnemonic at different account indices. That's
    /// enough for a 2-of-3 ScriptNofK and avoids the test having to ship three independent
    /// BIP-39 phrases.
    private func makeCosigners(
        count: Int = 3,
        network: Network = .preprod
    ) async throws -> [Cosigner] {
        var out: [Cosigner] = []
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        for i in 0..<count {
            let account = Account(index: UInt32(i), network: network)
            let path = account.paymentPath(role: .external, index: 0)
            let vkey = try await km.paymentVerificationKey(at: path)
            let hash = try vkey.hash()
            let skey = try await km.paymentSigningKeyType(at: path)
            out.append(Cosigner(
                account: account,
                keyManager: km,
                path: path,
                keyHash: hash,
                signingKey: skey
            ))
        }
        return out
    }

    /// A throwaway base address from the same test mnemonic at account 99 — distinct from
    /// any of the cosigners above.
    private func sampleDestination() async throws -> Address {
        let acct = Account(index: 99, network: .preprod)
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        return try await acct.address(with: km)
    }

    // MARK: - MultisigPolicy

    @Test func nOfMRejectsZeroOrTooLargeThreshold() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let hashes = cosigners.map(\.keyHash)
        do {
            _ = try MultisigPolicy.nOfM(required: 0, signerKeyHashes: hashes, network: .preprod)
            Issue.record("Expected configurationMissing for required=0")
        } catch WalletError.configurationMissing {
            // expected
        }
        do {
            _ = try MultisigPolicy.nOfM(required: 4, signerKeyHashes: hashes, network: .preprod)
            Issue.record("Expected configurationMissing for required > N")
        } catch WalletError.configurationMissing {
            // expected
        }
    }

    @Test func nOfMHasStableScriptHash() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let hashes = cosigners.map(\.keyHash)
        let p1 = try MultisigPolicy.nOfM(required: 2, signerKeyHashes: hashes, network: .preprod)
        let p2 = try MultisigPolicy.nOfM(required: 2, signerKeyHashes: hashes, network: .preprod)
        #expect(try p1.scriptHash() == p2.scriptHash())
    }

    @Test func differentThresholdsProduceDifferentScriptHashes() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let hashes = cosigners.map(\.keyHash)
        let two = try MultisigPolicy.nOfM(required: 2, signerKeyHashes: hashes, network: .preprod)
        let three = try MultisigPolicy.nOfM(required: 3, signerKeyHashes: hashes, network: .preprod)
        #expect(try two.scriptHash() != three.scriptHash())
    }

    @Test func paymentAddressUsesScriptHashCredential() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let address = try policy.enterpriseAddress()
        if case .scriptHash(let sh) = address.paymentPart {
            #expect(try sh == policy.scriptHash())
        } else {
            Issue.record("Expected scriptHash payment part, got \(String(describing: address.paymentPart))")
        }
        // Enterprise: no staking part.
        #expect(address.stakingPart == nil)
    }

    @Test func signerKeyHashesFlattensTree() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        #expect(Set(policy.signerKeyHashes()) == Set(cosigners.map(\.keyHash)))
    }

    @Test func requiredSignerCountReportsThreshold() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        #expect(policy.requiredSignerCount() == 2)
    }

    // MARK: - End-to-end build → sign → combine → submit

    @Test func twoOfThreeFlowProducesSignedTransactionWithBothWitnessesAndScript() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let scriptAddress = try policy.enterpriseAddress()

        // Fund the script address with a single big UTxO.
        let utxo = try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: NetworkId.testnet,
            utxos: [try scriptAddress.toBech32(): [utxo]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)

        // Sanity: the wallet sees the funding UTxO.
        let observed = try await wallet.utxos()
        #expect(observed.count == 1)
        let bal = try await wallet.balance()
        #expect(bal.lovelace == 50_000_000)

        // Build an unsigned send.
        let dest = try await sampleDestination()
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)

        // Witness set should already carry the policy's native script.
        let nativeScripts = prepared.transaction.transactionWitnessSet.nativeScripts?.asList ?? []
        #expect(nativeScripts.count == 1)
        #expect(try nativeScripts.first?.scriptHash() == policy.scriptHash())

        // No vkey witnesses yet — that's the point.
        let preWitnesses = prepared.transaction.transactionWitnessSet.vkeyWitnesses?.asList ?? []
        #expect(preWitnesses.isEmpty)

        // Two cosigners (indices 0 and 2) sign locally and ship partials to the coordinator.
        let p0 = try prepared.signLocal(with: cosigners[0].signingKey)
        let p2 = try prepared.signLocal(with: cosigners[2].signingKey)
        #expect(p0.bodyHash == prepared.bodyHash)
        #expect(p2.bodyHash == prepared.bodyHash)

        // Coordinator combines.
        let signed = try prepared.combine([p0, p2])

        guard case .nonEmptyOrderedSet(let set) = signed.transaction.transactionWitnessSet.vkeyWitnesses else {
            Issue.record("Expected non-empty witnesses on combined tx")
            return
        }
        #expect(set.elements.count == 2)

        // Native script survived the merge.
        let mergedScripts = signed.transaction.transactionWitnessSet.nativeScripts?.asList ?? []
        #expect(mergedScripts.count == 1)

        // And it can be submitted (stub will record the CBOR and return a fake txid).
        let txid = try await signed.submit()
        #expect(txid.hasPrefix("stubtx-"))
        #expect(stub.submittedCBOR.count == 1)
    }

    @Test func combineRejectsInsufficientSigners() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let scriptAddress = try policy.enterpriseAddress()
        let utxo = try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: NetworkId.testnet,
            utxos: [try scriptAddress.toBech32(): [utxo]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        let prepared = try await wallet.prepareSend(
            lovelace: 5_000_000,
            to: try await sampleDestination()
        )

        let onlyOne = try prepared.signLocal(with: cosigners[0].signingKey)
        do {
            _ = try prepared.combine([onlyOne])
            Issue.record("Expected signingFailed for under-threshold combine")
        } catch let WalletError.signingFailed(detail) {
            #expect(detail.contains("requires"))
        }
    }

    @Test func combineDeduplicatesSameSignerSubmittingTwice() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let scriptAddress = try policy.enterpriseAddress()
        let utxo = try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: NetworkId.testnet,
            utxos: [try scriptAddress.toBech32(): [utxo]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        let prepared = try await wallet.prepareSend(
            lovelace: 5_000_000,
            to: try await sampleDestination()
        )

        // Cosigner 0 submits twice, cosigner 1 once. After dedup we have 2 distinct signers.
        let p0a = try prepared.signLocal(with: cosigners[0].signingKey)
        let p0b = try prepared.signLocal(with: cosigners[0].signingKey)
        let p1 = try prepared.signLocal(with: cosigners[1].signingKey)
        let signed = try prepared.combine([p0a, p0b, p1])
        guard case .nonEmptyOrderedSet(let set) = signed.transaction.transactionWitnessSet.vkeyWitnesses else {
            Issue.record("Expected witnesses present")
            return
        }
        #expect(set.elements.count == 2)
    }

    @Test func combineRejectsPartialFromOutsider() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let outsider = try await makeCosigners(count: 5)[4]  // index 4 — not in the policy
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let scriptAddress = try policy.enterpriseAddress()
        let utxo = try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: NetworkId.testnet,
            utxos: [try scriptAddress.toBech32(): [utxo]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        let prepared = try await wallet.prepareSend(
            lovelace: 5_000_000,
            to: try await sampleDestination()
        )

        let p0 = try prepared.signLocal(with: cosigners[0].signingKey)
        let pOutsider = try prepared.signLocal(with: outsider.signingKey)
        do {
            _ = try prepared.combine([p0, pOutsider])
            Issue.record("Expected signingFailed for outsider partial")
        } catch let WalletError.signingFailed(detail) {
            #expect(detail.contains("not part of the multisig policy"))
        }
    }

    @Test func combineRejectsMismatchedBodyHash() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let scriptAddress = try policy.enterpriseAddress()
        let utxo = try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: NetworkId.testnet,
            utxos: [try scriptAddress.toBech32(): [utxo]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        let preparedA = try await wallet.prepareSend(lovelace: 5_000_000, to: try await sampleDestination())
        let preparedB = try await wallet.prepareSend(lovelace: 6_000_000, to: try await sampleDestination())

        // Cosigner 0 signs B by mistake; coordinator tries to combine into A.
        let pForB = try preparedB.signLocal(with: cosigners[0].signingKey)
        let pForA = try preparedA.signLocal(with: cosigners[1].signingKey)
        do {
            _ = try preparedA.combine([pForA, pForB])
            Issue.record("Expected signingFailed for mismatched body hash")
        } catch let WalletError.signingFailed(detail) {
            #expect(detail.contains("body hash"))
        }
    }

    // MARK: - PartialWitness CBOR round-trip

    @Test func partialWitnessRoundTripsThroughCBOR() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let scriptAddress = try policy.enterpriseAddress()
        let utxo = try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: NetworkId.testnet,
            utxos: [try scriptAddress.toBech32(): [utxo]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: try await sampleDestination())

        let original = try prepared.signLocal(with: cosigners[0].signingKey)
        let encoded = try original.exportCBOR()
        let restored = try PartialWitness.fromCBOR(encoded)

        #expect(restored.bodyHash == original.bodyHash)
        // The vkey + signature should both round-trip byte-identical.
        #expect(restored.witness.vkey.payload == original.witness.vkey.payload)
        #expect(restored.witness.signature == original.witness.signature)
    }

    // MARK: - Wallet kind

    @Test func walletKindReportsMultisig() async throws {
        let cosigners = try await makeCosigners(count: 3)
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: cosigners.map(\.keyHash),
            network: .preprod
        )
        let stub = StubChainContext(networkId: NetworkId.testnet)
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        #expect(wallet.kind == .multisig)
    }
}
