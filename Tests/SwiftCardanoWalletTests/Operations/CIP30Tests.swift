import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoCIPs
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

private let testWalletInfo = WalletInfo(
    name: "SwiftCardanoWallet Tests",
    icon: "data:image/png;base64,iVBORw0KGgo="
)

@Suite("MnemonicWallet.cip30Provider builds a KeyStoreCIP30Provider")
struct CIP30Tests {

    private func wallet(funding: Int64 = 10_000_000, network: Network = .preprod)
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

    private func provider(
        for wallet: MnemonicWallet,
        policy: CIP30ApprovalPolicy = .allowAll
    ) async throws -> KeyStoreCIP30Provider {
        try await wallet.cip30Provider(info: testWalletInfo, policy: policy)
    }

    /// Count vkey witnesses across every shape the encoder can emit
    /// (`.list`, `.nonEmptyOrderedSet`, `.indefiniteList`, or absent).
    private func witnessCount(_ set: TransactionWitnessSet) -> Int {
        switch set.vkeyWitnesses {
        case .none: return 0
        case .some(.list(let xs)): return xs.count
        case .some(.nonEmptyOrderedSet(let s)): return s.elements.count
        case .some(.indefiniteList(let xs)): return xs.count
        }
    }

    @Test func networkIdMatchesNetwork() async throws {
        let mainnet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { StubChainContext(networkId: .mainnet) })
        )
        let mainnetProvider = try await provider(for: mainnet)
        #expect(try await mainnetProvider.getNetworkId() == 1)

        let testnet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let testnetProvider = try await provider(for: testnet)
        #expect(try await testnetProvider.getNetworkId() == 0)
    }

    @Test func getUtxosReturnsCBOREncodedSet() async throws {
        let (wallet, _, _) = try await wallet()
        let cipProvider = try await provider(for: wallet)
        let utxosCBOR = try await cipProvider.getUtxos(amount: nil, paginate: nil)
        #expect(utxosCBOR != nil)
        #expect(utxosCBOR?.count == 1)
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
        let cipProvider = try await provider(for: wallet)
        let utxosCBOR = try await cipProvider.getUtxos(amount: nil, paginate: nil)
        #expect(utxosCBOR == nil)
    }

    @Test func getBalanceEncodesValueAsCBOR() async throws {
        let (wallet, _, _) = try await wallet(funding: 7_777_777)
        let cipProvider = try await provider(for: wallet)
        let balanceCBOR = try await cipProvider.getBalance()
        let parsed = try Value.fromCBOR(data: balanceCBOR)
        #expect(parsed.coin == 7_777_777)
    }

    @Test func getChangeAddressRoundTrips() async throws {
        let (wallet, _, _) = try await wallet()
        let cipProvider = try await provider(for: wallet)
        let cbor = try await cipProvider.getChangeAddress()
        let parsed = try Address.fromCBOR(data: cbor)
        // KeyStoreCIP30Provider's change address is the role-0 / index-0 receive — same
        // address the wallet calls "receive". The wallet's own changeAddress() is role-1.
        let expectedReceive = try await wallet.receiveAddress()
        #expect(parsed == expectedReceive)
    }

    @Test func getRewardAddressesProducesOneEntry() async throws {
        let (wallet, _, _) = try await wallet()
        let cipProvider = try await provider(for: wallet)
        let cbor = try await cipProvider.getRewardAddresses()
        #expect(cbor.count == 1)
        let parsed = try Address.fromCBOR(data: cbor[0])
        let expected = try await wallet.rewardAddress()
        #expect(parsed == expected)
    }

    @Test func getUsedAddressesIncludesFundedReceive() async throws {
        let (wallet, _, receive) = try await wallet()
        let cipProvider = try await provider(for: wallet)
        let cbor = try await cipProvider.getUsedAddresses(paginate: nil)
        let parsed = try cbor.map { try Address.fromCBOR(data: $0) }
        #expect(parsed.contains(receive))
    }

    @Test func getUnusedAddressesIsEmptyOnceFunded() async throws {
        let (wallet, _, _) = try await wallet()
        let cipProvider = try await provider(for: wallet)
        let cbor = try await cipProvider.getUnusedAddresses()
        // Single-address provider: once the address has a UTxO it's "used", so there
        // are no unused addresses to report.
        #expect(cbor.isEmpty)
    }

    // MARK: - Approval policy

    @Test func denyAllPolicyRejectsSignTx() async throws {
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)
        let txCBOR = prepared.exportCBOR()

        let cipProvider = try await provider(for: wallet, policy: .denyAll)
        await #expect(throws: TxSignError.self) {
            _ = try await cipProvider.signTx(txCBOR, partialSign: false)
        }
    }

    @Test func denyAllPolicyRejectsSignData() async throws {
        let (wallet, _, _) = try await wallet()
        let receive = try await wallet.receiveAddress()
        let bech32 = try receive.toBech32()
        let cipProvider = try await provider(for: wallet, policy: .denyAll)
        await #expect(throws: DataSignError.self) {
            _ = try await cipProvider.signData(
                address: bech32,
                payload: Data("hello".utf8)
            )
        }
    }

    @Test func denyAllPolicyRejectsSubmitTx() async throws {
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let signed = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient).sign()
        let cipProvider = try await provider(for: wallet, policy: .denyAll)
        await #expect(throws: TxSendError.self) {
            _ = try await cipProvider.submitTx(signed.exportCBOR())
        }
    }

    // MARK: - Sign / submit (allowAll policy)

    @Test func signTxReturnsWitnessSetWithOneVKeyWitness() async throws {
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)
        let txCBOR = prepared.exportCBOR()

        let cipProvider = try await provider(for: wallet)
        let witnessSetCBOR = try await cipProvider.signTx(txCBOR, partialSign: false)
        let witnessSet = try TransactionWitnessSet.fromCBOR(data: witnessSetCBOR)
        #expect(witnessCount(witnessSet) == 1)
    }

    @Test func partialSignFalseThrowsWhenRequiredSignerMissing() async throws {
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        var prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)

        // Add a required signer the wallet does not own — partialSign:false must reject.
        let foreignHash = VerificationKeyHash(payload: Data(repeating: 0x42, count: 28))
        var body = prepared.transaction.transactionBody
        body.requiredSigners = .nonEmptyOrderedSet(NonEmptyOrderedSet([foreignHash]))
        let mutated = Transaction(
            transactionBody: body,
            transactionWitnessSet: prepared.transaction.transactionWitnessSet,
            valid: prepared.transaction.valid,
            auxiliaryData: prepared.transaction.auxiliaryData
        )
        prepared = PreparedTransaction(
            transaction: mutated,
            signingPaths: prepared.signingPaths,
            chainContext: prepared.chainContext,
            keyManager: prepared.keyManager
        )

        let cipProvider = try await provider(for: wallet)
        await #expect(throws: TxSignError.self) {
            _ = try await cipProvider.signTx(prepared.exportCBOR(), partialSign: false)
        }
    }

    @Test func partialSignTrueIgnoresMissingRequiredSigners() async throws {
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        var prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)

        // Foreign required signer — partialSign:true should sign anyway with whatever keys
        // we have rather than rejecting.
        let foreignHash = VerificationKeyHash(payload: Data(repeating: 0x42, count: 28))
        var body = prepared.transaction.transactionBody
        body.requiredSigners = .nonEmptyOrderedSet(NonEmptyOrderedSet([foreignHash]))
        let mutated = Transaction(
            transactionBody: body,
            transactionWitnessSet: prepared.transaction.transactionWitnessSet,
            valid: prepared.transaction.valid,
            auxiliaryData: prepared.transaction.auxiliaryData
        )
        prepared = PreparedTransaction(
            transaction: mutated,
            signingPaths: prepared.signingPaths,
            chainContext: prepared.chainContext,
            keyManager: prepared.keyManager
        )

        let cipProvider = try await provider(for: wallet)
        let witnessSetCBOR = try await cipProvider.signTx(prepared.exportCBOR(), partialSign: true)
        let witnessSet = try TransactionWitnessSet.fromCBOR(data: witnessSetCBOR)
        #expect(witnessCount(witnessSet) >= 1)
    }

    @Test func submitTxDispatchesToChainContext() async throws {
        let (wallet, stub, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let signed = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient).sign()
        let cipProvider = try await provider(for: wallet)
        let txId = try await cipProvider.submitTx(signed.exportCBOR())
        #expect(txId.hasPrefix("stubtx-"))
        #expect(stub.submittedCBOR.count == 1)
    }

    @Test func signDataProducesHexSignatureAndKey() async throws {
        let (wallet, _, _) = try await wallet()
        let receive = try await wallet.receiveAddress()
        let bech32 = try receive.toBech32()
        let cipProvider = try await provider(for: wallet)
        let result = try await cipProvider.signData(
            address: bech32,
            payload: Data("hello cardano".utf8)
        )
        #expect(!result.signature.isEmpty)
        #expect(!result.key.isEmpty)
    }

    @Test func signDataAcceptsStakeAddress() async throws {
        let (wallet, _, _) = try await wallet()
        let stakeBech32 = try await wallet.rewardAddress().toBech32()
        let cipProvider = try await provider(for: wallet)
        let result = try await cipProvider.signData(
            address: stakeBech32,
            payload: Data("stake msg".utf8)
        )
        #expect(!result.signature.isEmpty)
    }

    /// Raw bytes that are not valid UTF-8 — previously this would have been hex-encoded
    /// before signing. With the new provider the bytes are signed verbatim.
    @Test func signDataAcceptsNonUTF8Payload() async throws {
        let (wallet, _, _) = try await wallet()
        let receive = try await wallet.receiveAddress()
        let bech32 = try receive.toBech32()
        let cipProvider = try await provider(for: wallet)
        // Invalid UTF-8: lone continuation byte.
        let payload = Data([0x80, 0xff, 0x00, 0xfe])
        let result = try await cipProvider.signData(address: bech32, payload: payload)
        #expect(!result.signature.isEmpty)
    }

    /// Mirrors the closure-based ``CIP30ApprovalPolicy`` shape shown in the README and
    /// the CIP-30 article. The closures see every approval call with the same arguments
    /// the docs claim — confirms the example as written actually compiles and runs.
    @Test func closureBasedPolicyReceivesApprovalCallsWithDocumentedArguments() async throws {
        let (wallet, _, _) = try await wallet(funding: 10_000_000)
        let recipient = try await wallet.changeAddress()
        let prepared = try await wallet.prepareSend(lovelace: 2_000_000, to: recipient)
        let txCBOR = prepared.exportCBOR()

        // Capture the arguments each approver sees so we can assert on them.
        actor Recorder {
            var signTxCalls: [(tx: Transaction, partialSign: Bool, originIsNil: Bool)] = []
            var signDataCalls: [(address: Address, payload: Data, originIsNil: Bool)] = []
            var submitOriginIsNil: [Bool] = []
            func recordSignTx(_ tx: Transaction, _ ps: Bool, _ ctx: CIP30RequestContext?) {
                signTxCalls.append((tx, ps, ctx == nil))
            }
            func recordSignData(_ a: Address, _ p: Data, _ ctx: CIP30RequestContext?) {
                signDataCalls.append((a, p, ctx == nil))
            }
            func recordSubmit(_ ctx: CIP30RequestContext?) {
                submitOriginIsNil.append(ctx == nil)
            }
        }
        let recorder = Recorder()

        let policy = CIP30ApprovalPolicy(
            approveSignTx: { tx, partialSign, context in
                await recorder.recordSignTx(tx, partialSign, context)
                return true
            },
            approveSignData: { address, payload, context in
                await recorder.recordSignData(address, payload, context)
                return true
            },
            approveSubmitTx: { _, context in
                await recorder.recordSubmit(context)
                return true
            }
        )

        let cipProvider = try await wallet.cip30Provider(info: testWalletInfo, policy: policy)

        // Drive signTx — approver fires with the decoded Transaction and partialSign flag.
        _ = try await cipProvider.signTx(txCBOR, partialSign: true)
        let signTxCalls = await recorder.signTxCalls
        #expect(signTxCalls.count == 1)
        #expect(signTxCalls[0].partialSign == true)
        #expect(signTxCalls[0].originIsNil)
        // Body matches what we built (round-trip via CBOR).
        let recordedBodyHash = signTxCalls[0].tx.transactionBody.hash()
        let expectedBodyHash = prepared.transaction.transactionBody.hash()
        #expect(recordedBodyHash == expectedBodyHash)

        // Drive signData — approver fires with the parsed Address and raw payload bytes.
        let receive = try await wallet.receiveAddress()
        let payload = Data([0x01, 0x02, 0x03])
        _ = try await cipProvider.signData(address: try receive.toBech32(), payload: payload)
        let signDataCalls = await recorder.signDataCalls
        #expect(signDataCalls.count == 1)
        #expect(signDataCalls[0].address == receive)
        #expect(signDataCalls[0].payload == payload)
        #expect(signDataCalls[0].originIsNil)

        // Drive submitTx — approver fires with the raw CBOR and no origin in this path.
        let signed = try await prepared.sign()
        _ = try await cipProvider.submitTx(signed.exportCBOR())
        let submitOriginIsNil = await recorder.submitOriginIsNil
        #expect(submitOriginIsNil.count == 1)
        #expect(submitOriginIsNil[0])
    }
}
