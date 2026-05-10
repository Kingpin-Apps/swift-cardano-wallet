import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("Mint / burn / mintNFT")
struct MintTests {

    /// Build a wallet whose receive address holds enough ADA to cover the mint output
    /// + fee + change. 50 ADA is more than enough for any of the txs we build here.
    private func wallet(funding: Int = 50_000_000, network: Network = .preprod) async throws
    -> (wallet: MnemonicWallet, stub: StubChainContext, receive: Address)
    {
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

    /// One-shot policy bound to the wallet's payment key — same shape as mintNFT uses
    /// internally, but with a fixed slot so the test fixtures don't drift.
    private func walletOneShotPolicy(for wallet: MnemonicWallet) async throws -> NativeScript {
        let vkey = try await wallet.keyManager.paymentVerificationKey(
            at: wallet.account.paymentPath(role: .external, index: 0)
        )
        let kh = try vkey.hash()
        return .scriptAll(
            ScriptAll(scripts: [
                .scriptPubkey(ScriptPubkey(keyHash: kh)),
                .invalidHereAfter(AfterScript(slot: 99_999_999)),
            ])
        )
    }

    // MARK: - prepareMint

    @Test func prepareMintProducesMintFieldAndOutput() async throws {
        let (wallet, _, receive) = try await wallet()
        let policy = try await walletOneShotPolicy(for: wallet)
        let policyId = try policy.scriptHash()

        let prepared = try await wallet.prepareMint(
            amount: 5,
            assetName: "MyToken",
            policy: policy
        )
        let body = prepared.transaction.transactionBody
        #expect(body.mint != nil)
        let mintAsset = body.mint?.data[policyId]
        #expect(mintAsset != nil)
        #expect(mintAsset?[try AssetName(from: "MyToken")] == 5)

        // An output for the recipient with the same asset.
        let mintOutput = body.outputs.first { $0.address == receive && !$0.amount.multiAsset.data.isEmpty }
        #expect(mintOutput != nil)
        #expect(mintOutput?.amount.multiAsset.data[policyId]?[try AssetName(from: "MyToken")] == 5)
    }

    @Test func mintIncludesPolicyAsNativeScriptInWitnessSet() async throws {
        let (wallet, _, _) = try await wallet()
        let policy = try await walletOneShotPolicy(for: wallet)
        let prepared = try await wallet.prepareMint(amount: 1, assetName: "Tok", policy: policy)
        let signed = try await prepared.sign()
        guard case .nonEmptyOrderedSet(let scripts) = signed.transaction.transactionWitnessSet.nativeScripts else {
            Issue.record("Expected nativeScripts in witness set")
            return
        }
        #expect(scripts.elements.count == 1)
    }

    @Test func zeroMintRejected() async throws {
        let (wallet, _, _) = try await wallet()
        let policy = try await walletOneShotPolicy(for: wallet)
        do {
            _ = try await wallet.prepareMint(amount: 0, assetName: "Tok", policy: policy)
            Issue.record("Expected unsupportedOperation")
        } catch let error as WalletError {
            switch error {
            case .unsupportedOperation: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func mintAttachesMetadataWhenProvided() async throws {
        let (wallet, _, _) = try await wallet()
        let policy = try await walletOneShotPolicy(for: wallet)
        let metadata: [TransactionMetadatumLabel: TransactionMetadatum] = [
            42: .text("hello"),
        ]
        let prepared = try await wallet.prepareMint(
            amount: 1,
            assetName: "Tok",
            policy: policy,
            metadata: metadata
        )
        #expect(prepared.transaction.auxiliaryData != nil)
    }

    // MARK: - burn

    @Test func prepareBurnProducesNegativeMint() async throws {
        // For burn we need a UTxO at the receive address that holds the asset to burn.
        let network = Network.preprod
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        let policy = try await walletOneShotPolicy(for: probe)
        let policyId = try policy.scriptHash()
        let assetName = try AssetName(from: "BurnMe")

        // Seed two UTxOs: one with 50 ADA for fees, one carrying 10 of the asset.
        let feeUTxO = try TestFixtures.makeUTxO(at: receive, lovelace: 50_000_000, index: 0)
        let assetUTxO = try {
            let txInput = try TransactionInput(from: TestFixtures.dummyTxId, index: 1)
            let value = Value(coin: 2_000_000, multiAsset: MultiAsset([
                policyId: Asset([assetName: 10])
            ]))
            return UTxO(input: txInput, output: TransactionOutput(address: receive, amount: value))
        }()
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [try receive.toBech32(): [feeUTxO, assetUTxO]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub }),
            gapLimit: 3
        )

        let prepared = try await wallet.prepareBurn(
            amount: 7,
            assetName: "BurnMe",
            policy: policy
        )
        let body = prepared.transaction.transactionBody
        #expect(body.mint?.data[policyId]?[assetName] == -7)
    }

    // MARK: - mintNFT

    @Test func prepareMintNFTAttachesCip25Metadata() async throws {
        let (wallet, _, _) = try await wallet()
        let metadata = CIP25NFTMetadata(
            name: "Coolest NFT",
            image: "ipfs://bafy.../coolest.png",
            mediaType: "image/png",
            description: "Test NFT",
            files: [CIP25File(name: "preview", mediaType: "image/png", src: "ipfs://...")],
            extras: ["artist": "Anonymous"]
        )

        let prepared = try await wallet.prepareMintNFT(
            name: "CoolestNFT",
            metadata: metadata,
            ttlSlotsFromNow: 1_000_000
        )

        // Body has mint amount = 1 of the named asset.
        let body = prepared.transaction.transactionBody
        let mintData = body.mint?.data ?? [:]
        #expect(mintData.count == 1)
        let expectedAssetName = try AssetName(from: "CoolestNFT")
        var sawNFT = false
        for (_, asset) in mintData {
            for (an, qty) in asset.data where an == expectedAssetName {
                #expect(qty == 1)
                sawNFT = true
            }
        }
        #expect(sawNFT)

        // Auxiliary data carries the CIP-25 envelope at label 721.
        #expect(prepared.transaction.auxiliaryData != nil)
    }

    @Test func mintNFTSignsAndSubmits() async throws {
        let (wallet, stub, _) = try await wallet()
        let metadata = CIP25NFTMetadata(name: "Tiny", image: "ipfs://x")
        let txId = try await wallet.mintNFT(
            name: "Tiny",
            metadata: metadata,
            ttlSlotsFromNow: 100_000
        )
        #expect(txId.hasPrefix("stubtx-"))
        #expect(stub.submittedCBOR.count == 1)
    }

    // MARK: - CIP-14 fingerprint

    @Test func assetFingerprintIsBech32Asset1() async throws {
        let (wallet, _, _) = try await wallet()
        let policy = try await walletOneShotPolicy(for: wallet)
        let policyId = try policy.scriptHash()
        let fp = try wallet.assetFingerprint(
            policyId: policyId,
            assetName: try AssetName(from: "Tok")
        )
        #expect(fp.hasPrefix("asset1"))
        // Same inputs → same fingerprint.
        let fp2 = try wallet.assetFingerprint(
            policyId: policyId,
            assetName: try AssetName(from: "Tok")
        )
        #expect(fp == fp2)
    }

    @Test func cip25EncodingShape() throws {
        let policyHex = String(repeating: "ab", count: 28)
        let policyId = try ScriptHash(payload: Data(hex: policyHex))
        let metadata = CIP25NFTMetadata(name: "MyNFT", image: "ipfs://x", description: "y")
        let encoded = metadata.encode(policyId: policyId, assetName: "MyNFT")
        guard case .map(let top) = encoded else {
            Issue.record("Expected top-level map")
            return
        }
        // Has both the policy entry and a "version" tag.
        #expect(top[.text(policyHex)] != nil)
        #expect(top[.text("version")] == .int(1))
        // Drill into the asset record.
        guard case .map(let policyMap) = top[.text(policyHex)] else {
            Issue.record("Expected policy map")
            return
        }
        guard case .map(let asset) = policyMap[.text("MyNFT")] else {
            Issue.record("Expected asset map")
            return
        }
        #expect(asset[.text("name")] == .text("MyNFT"))
        #expect(asset[.text("image")] == .text("ipfs://x"))
        #expect(asset[.text("description")] == .text("y"))
    }
}
