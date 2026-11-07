import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

/// Resolves every handle to one fixed address.
private actor FixedHandleResolver: HandleResolver {
    let address: Address
    init(_ address: Address) { self.address = address }
    func resolve(_ handle: String) async throws -> Address { address }
    func clearCache() async {}
}

private func envelope(type: String, cborHex: String) -> Data {
    Data(#"{"type":"\#(type)","description":"x","cborHex":"\#(cborHex)"}"#.utf8)
}

@Suite("Security regressions from the 2026-11-07 audit")
struct SecurityRegressionTests {

    // MARK: - Mint: provider tip slot

    private func mintWallet(slot: Int) async throws -> MnemonicWallet {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let receive = try await probe.receiveAddress()
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try receive.toBech32(): [try TestFixtures.makeUTxO(at: receive, lovelace: 50_000_000)]]
        )
        stub.lastSlot = slot
        return try await MnemonicWallet(mnemonic: testMnemonic, network: .preprod, provider: .custom(make: { stub }))
    }

    @Test(arguments: [Int.max, -200_000])
    func mintNFTRejectsOutOfRangeTipSlot(slot: Int) async throws {
        let wallet = try await mintWallet(slot: slot)
        await #expect(throws: WalletError.self) {
            _ = try await wallet.prepareMintNFT(name: "N", metadata: CIP25NFTMetadata(name: "N", image: "ipfs://x"))
        }
    }

    @Test func mintNFTRejectsNonPositiveTTL() async throws {
        let wallet = try await mintWallet(slot: 50_000_000)
        await #expect(throws: WalletError.self) {
            _ = try await wallet.prepareMintNFT(
                name: "N", metadata: CIP25NFTMetadata(name: "N", image: "ipfs://x"), ttlSlotsFromNow: 0
            )
        }
        _ = try await wallet.prepareMintNFT(name: "N", metadata: CIP25NFTMetadata(name: "N", image: "ipfs://x"))
    }

    // MARK: - Send to handle: destination checks

    private func handleWallet(network: Network, resolvesTo address: Address) async throws -> MnemonicWallet {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [try receive.toBech32(): [try TestFixtures.makeUTxO(at: receive, lovelace: 5_000_000_000)]]
        )
        return try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            handleResolver: FixedHandleResolver(address)
        )
    }

    @Test func prepareSendToRejectsScriptStakeAndWrongNetworkDestinations() async throws {
        let script = try Address(
            paymentPart: .scriptHash(ScriptHash(payload: Data(repeating: 0x5c, count: 28))),
            network: .mainnet
        )
        let otherNetwork = try Address(
            paymentPart: .verificationKeyHash(VerificationKeyHash(payload: Data(repeating: 0x11, count: 28))),
            network: .testnet
        )
        let stakeOnly = try Address(
            stakingPart: .verificationKeyHash(VerificationKeyHash(payload: Data(repeating: 0x22, count: 28))),
            network: .mainnet
        )
        for destination in [script, otherNetwork, stakeOnly] {
            let wallet = try await handleWallet(network: .mainnet, resolvesTo: destination)
            await #expect(throws: WalletError.self) {
                _ = try await wallet.prepareSendTo(handle: "$x", lovelace: 100_000_000)
            }
        }
        let good = try Address(
            paymentPart: .verificationKeyHash(VerificationKeyHash(payload: Data(repeating: 0x33, count: 28))),
            network: .mainnet
        )
        let wallet = try await handleWallet(network: .mainnet, resolvesTo: good)
        _ = try await wallet.prepareSendTo(handle: "$x", lovelace: 100_000_000)
    }

    @Test func defaultResolverAcceptsOnlyMainnetKeyHashAddresses() throws {
        let script = try Address(
            paymentPart: .scriptHash(ScriptHash(payload: Data(repeating: 0x5c, count: 28))),
            network: .mainnet
        ).toBech32()
        let testnet = try Address(
            paymentPart: .verificationKeyHash(VerificationKeyHash(payload: Data(repeating: 0x11, count: 28))),
            network: .testnet
        ).toBech32()
        let stake = try Address(
            stakingPart: .verificationKeyHash(VerificationKeyHash(payload: Data(repeating: 0x22, count: 28))),
            network: .mainnet
        ).toBech32()
        for bech32 in [script, testnet, stake] {
            #expect(throws: WalletError.self) {
                _ = try DefaultHandleResolver.validatedPaymentAddress(bech32, handle: "x")
            }
        }
        let good = try Address(
            paymentPart: .verificationKeyHash(VerificationKeyHash(payload: Data(repeating: 0x33, count: 28))),
            network: .mainnet
        ).toBech32()
        _ = try DefaultHandleResolver.validatedPaymentAddress(good, handle: "x")
    }

    // MARK: - TextEnvelope import

    @Test(arguments: ["", "5", "abc"])
    func malformedCborHexThrows(cborHex: String) {
        #expect(throws: WalletError.self) {
            _ = try TextEnvelopeKeyManager.parseSkey(
                envelope(type: PaymentSigningKey.TYPE, cborHex: cborHex), role: .payment
            )
        }
    }

    @Test func extendedSkeyWithForeignPublicKeyIsRejected() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let own = try await km.paymentSigningKey(at: .payment(account: 0, index: 0)).payload
        let other = try await km.paymentSigningKey(at: .payment(account: 5, index: 0)).payload
        let tampered = own.prefix(64) + other[other.startIndex + 64 ..< other.startIndex + 96] + own.suffix(32)
        #expect(tampered.count == 128)

        #expect(throws: WalletError.self) {
            _ = try TextEnvelopeKeyManager.parseSkey(
                envelope(type: PaymentExtendedSigningKey.TYPE, cborHex: "5880" + tampered.toHex),
                role: .payment
            )
        }
        // The in-memory init can't throw, so the check runs when the key is first used.
        let manager = TextEnvelopeKeyManager(paymentPayload: Data(tampered), paymentIsExtended: true)
        await #expect(throws: WalletError.self) {
            _ = try await manager.paymentVerificationKey(at: .payment(account: 0, index: 0))
        }
        // The untampered key still loads.
        _ = try TextEnvelopeKeyManager.parseSkey(
            envelope(type: PaymentExtendedSigningKey.TYPE, cborHex: "5880" + own.toHex), role: .payment
        )
    }

    // MARK: - Multisig

    private struct Signer {
        let hash: VerificationKeyHash
        let key: SigningKeyType
        let vkey: VerificationKeyType
    }

    private func signers(_ count: Int) async throws -> [Signer] {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        var out: [Signer] = []
        for i in 0..<count {
            let path = Account(index: UInt32(i), network: .preprod).paymentPath(role: .external, index: 0)
            let key = try await km.paymentSigningKeyType(at: path)
            out.append(Signer(
                hash: try await km.paymentVerificationKey(at: path).hash(),
                key: key,
                vkey: try key.toVerificationKeyType()
            ))
        }
        return out
    }

    private func prepared(policy: MultisigPolicy) async throws -> PreparedMultisigTransaction {
        let scriptAddress = try policy.enterpriseAddress()
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try scriptAddress.toBech32(): [try TestFixtures.makeUTxO(at: scriptAddress, lovelace: 50_000_000)]]
        )
        let wallet = try MultisigWallet(policy: policy, chainContext: stub)
        let dest = try await Account(index: 99, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        return try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
    }

    @Test func negativeThresholdDoesNotTrap() async throws {
        let s = try await signers(1)
        let policy = MultisigPolicy(
            nativeScript: .scriptNofK(ScriptNofK(required: -1, scripts: [.scriptPubkey(ScriptPubkey(keyHash: s[0].hash))])),
            network: .preprod
        )
        #expect(policy.requiredSignerCount() == 0)
    }

    @Test func combineWithNoWitnessesForZeroSignerPolicyDoesNotTrap() async throws {
        let s = try await signers(1)
        let policy = MultisigPolicy(
            nativeScript: .scriptAny(ScriptAny(scripts: [
                .scriptPubkey(ScriptPubkey(keyHash: s[0].hash)),
                .invalidBefore(BeforeScript(slot: 1)),
            ])),
            network: .preprod
        )
        let tx = try await prepared(policy: policy)
        let signed = try tx.combine([])
        #expect(signed.transaction.transactionWitnessSet.vkeyWitnesses == nil)
    }

    @Test func combineRejectsForgedAndRelabelledPartials() async throws {
        let s = try await signers(3)
        let policy = try MultisigPolicy.nOfM(required: 2, signerKeyHashes: s.map(\.hash), network: .preprod)
        let tx = try await prepared(policy: policy)
        let bodyHash = try tx.bodyHash

        let genuine0 = try tx.signLocal(with: s[0].key)
        let genuine1 = try tx.signLocal(with: s[1].key)
        let forged = try PartialWitness.fromCBOR(PartialWitness(
            bodyHash: bodyHash,
            witness: VerificationKeyWitness(vkey: s[1].vkey, signature: Data(repeating: 0, count: 64))
        ).exportCBOR())
        let relabelled = PartialWitness(
            bodyHash: bodyHash,
            witness: VerificationKeyWitness(vkey: s[1].vkey, signature: try s[1].key.sign(data: Data(repeating: 0x42, count: 32)))
        )

        for partials in [[genuine0, forged], [genuine0, relabelled], [forged, genuine0, genuine1]] {
            #expect(throws: WalletError.self) { _ = try tx.combine(partials) }
        }
        let signed = try tx.combine([genuine0, genuine1])
        #expect(signed.transaction.transactionWitnessSet.vkeyWitnesses?.count == 2)
    }

    // MARK: - Plutus mint collateral

    @Test(arguments: [3_800_000 as Int64, 4_200_000])
    func plutusMintRefusesCollateralWithoutTotalCollateral(collateral: Int64) async throws {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let receive = try await probe.receiveAddress()
        let funding = try TestFixtures.makeUTxO(at: receive, lovelace: 100_000_000, index: 0)
        let small = try TestFixtures.makeUTxO(at: receive, lovelace: collateral, index: 1)
        let stub = StubChainContext(networkId: .testnet, utxos: [try receive.toBech32(): [funding, small]])
        let wallet = try await MnemonicWallet(mnemonic: testMnemonic, network: .preprod, provider: .custom(make: { stub }))
        let redeemer = Redeemer(
            tag: .mint,
            data: try Unit().toPlutusData(),
            exUnits: ExecutionUnits(mem: 5_000_000, steps: 1_000_000_000)
        )
        let script = PlutusScript.plutusV2Script(PlutusV2Script(data: Data([0x49, 0x48, 0x01, 0x00, 0x00, 0x32, 0x22, 0x33, 0x33])))
        do {
            let prepared = try await wallet.prepareMint(
                amount: 1, assetName: "T", plutusPolicy: script, redeemer: redeemer,
                collateral: [small]
            )
            // If the build succeeds it must declare total_collateral.
            #expect(prepared.transaction.transactionBody.totalCollateral != nil)
        } catch let error as WalletError {
            guard case .validationFailed(let detail) = error, detail.contains("total_collateral") else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - Balance tracking

    @Test func balanceIgnoresStoreEntriesFromOtherAccounts() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let foreign = try await Account(index: 3, network: .preprod).address(with: km)
        let store = InMemoryUTxOStore()
        try await store.upsert([try TestFixtures.makeUTxO(at: foreign, lovelace: 77_000_000)], for: foreign)

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) }),
            utxoStore: store,
            gapLimit: 3
        )
        #expect(try await wallet.balance().lovelace == 0)
        #expect(try await wallet.utxos().isEmpty)
    }

    @Test func sweepExtendsPastUsedAddressesAndPathsResolve() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .preprod)
        // Used addresses at 2 and 5 with gap limit 3: 5 is only reached because 2 is used.
        let a2 = try await acct.address(with: km, role: .external, index: 2)
        let a5 = try await acct.address(with: km, role: .external, index: 5)
        let a9 = try await acct.address(with: km, role: .external, index: 9)
        let stub = StubChainContext(networkId: .testnet, utxos: [
            try a2.toBech32(): [try TestFixtures.makeUTxO(at: a2, lovelace: 1_000_000, index: 0)],
            try a5.toBech32(): [try TestFixtures.makeUTxO(at: a5, lovelace: 2_000_000, index: 1)],
            try a9.toBech32(): [try TestFixtures.makeUTxO(at: a9, lovelace: 4_000_000, index: 2)],
        ])
        let tracker = BalanceTracker(account: acct, keyManager: km, chainContext: stub, gapLimit: 3)
        let utxos = try await tracker.utxos()
        // 9 is past the gap after 5 (6, 7, 8 empty), so it is not found.
        #expect(utxos.map(\.output.amount.coin).sorted() == [1_000_000, 2_000_000])
        #expect(try await tracker.paymentPath(for: a5) == acct.paymentPath(role: .external, index: 5))
        // External scanned 0..<9, change 0..<3.
        #expect(stub.queriedAddresses.count == 9 + 3)
    }

    @Test func zeroGapLimitStillScansOneAddress() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .preprod)
        let a0 = try await acct.address(with: km, role: .external, index: 0)
        let stub = StubChainContext(networkId: .testnet, utxos: [
            try a0.toBech32(): [try TestFixtures.makeUTxO(at: a0, lovelace: 1_000_000)],
        ])
        let tracker = BalanceTracker(account: acct, keyManager: km, chainContext: stub, gapLimit: 0)
        #expect(await tracker.gapLimit == 1)
        #expect(try await tracker.utxos().count == 1)
    }

    @Test func sweepIsCappedAtMaxAddressIndex() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(network: .preprod)
        var utxos: [String: [UTxO]] = [:]
        for i in UInt32(0)..<10 {
            let a = try await acct.address(with: km, role: .external, index: i)
            utxos[try a.toBech32()] = [try TestFixtures.makeUTxO(at: a, lovelace: 1_000_000, index: UInt16(i))]
        }
        let stub = StubChainContext(networkId: .testnet, utxos: utxos)
        let tracker = BalanceTracker(account: acct, keyManager: km, chainContext: stub, gapLimit: 2, maxAddressIndex: 4)
        #expect(try await tracker.utxos().count == 4)
    }
}
