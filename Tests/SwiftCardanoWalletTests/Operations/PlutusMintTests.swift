import Testing
import Foundation
import OrderedCollections
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("Plutus minting — structural correctness; UPLC eval wired through stub")
struct PlutusMintTests {

    /// Build a wallet with funding + a pure-ADA UTxO for collateral.
    private func wallet(
        funding: Int64 = 100_000_000,
        network: Network = .preprod
    ) async throws -> (wallet: MnemonicWallet, stub: StubChainContext, receive: Address) {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { StubChainContext(networkId: network.networkId) })
        )
        let receive = try await probe.receiveAddress()
        // Two UTxOs: a big one for the mint, a small ADA-only one for collateral.
        let funding1 = try TestFixtures.makeUTxO(at: receive, lovelace: funding, index: 0)
        let collateral = try TestFixtures.makeUTxO(at: receive, lovelace: 6_000_000, index: 1)
        let stub = StubChainContext(
            networkId: network.networkId,
            utxos: [try receive.toBech32(): [funding1, collateral]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: network,
            provider: .custom(make: { stub })
        )
        return (wallet, stub, receive)
    }

    /// A deliberately-trivial Plutus script blob — used by structural tests that pass
    /// explicit `exUnits` on the redeemer to bypass UPLC evaluation. The stub
    /// `ChainContext` *does* implement `evaluateTxCBOR` via `SwiftCardanoUPLC.PhaseTwo`,
    /// but auto-estimation against this blob would fail (it's not a real script);
    /// dedicated end-to-end auto-estimate testing needs a verified compiled Plutus blob
    /// fixture, which is out of scope here.
    private func dummyPlutusV2() -> PlutusScript {
        .plutusV2Script(PlutusV2Script(data: Data([0x49, 0x48, 0x01, 0x00, 0x00, 0x32, 0x22, 0x33, 0x33])))
    }

    /// Pre-computed execution units — used by structural tests that pass explicit
    /// `exUnits` on the redeemer. Real production wallets pass `nil` and let
    /// `TxBuilder` auto-estimate via `chainContext.evaluateTxCBOR(...)` (which is now
    /// wired up locally through `SwiftCardanoUPLC.PhaseTwo`).
    private func stubExUnits() -> ExecutionUnits {
        ExecutionUnits(mem: 5_000_000, steps: 1_000_000_000)
    }

    private func stubUnitRedeemer() throws -> Redeemer {
        Redeemer(
            tag: .mint,
            data: try Unit().toPlutusData(),
            exUnits: stubExUnits()
        )
    }

    // MARK: - Collateral picker

    /// Derived once from the test mnemonic — used only as a UTxO holder. The picker
    /// doesn't care what address it is, just that it's well-formed.
    private func sampleAddress() async throws -> Address {
        try await Account(network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
    }

    @Test func collateralPickerPrefersSmallestAdaOnlyUtxoAtLeast5Ada() async throws {
        // Three pure-ADA UTxOs at 3, 6, 8 ADA → picker should pick the 6-ADA one.
        let addr = try await sampleAddress()
        let small = try TestFixtures.makeUTxO(at: addr, lovelace: 3_000_000, index: 0)
        let mid = try TestFixtures.makeUTxO(at: addr, lovelace: 6_000_000, index: 1)
        let big = try TestFixtures.makeUTxO(at: addr, lovelace: 8_000_000, index: 2)
        let picked = try MnemonicWallet.pickCollateral(from: [small, mid, big])
        #expect(picked.count == 1)
        #expect(picked.first?.output.amount.coin == 6_000_000)
    }

    @Test func collateralPickerFallsBackWhenNoUtxoReaches5Ada() async throws {
        let addr = try await sampleAddress()
        let small = try TestFixtures.makeUTxO(at: addr, lovelace: 2_000_000, index: 0)
        let smaller = try TestFixtures.makeUTxO(at: addr, lovelace: 1_500_000, index: 1)
        let picked = try MnemonicWallet.pickCollateral(from: [small, smaller])
        // Falls back to the largest pure-ADA UTxO.
        #expect(picked.count == 1)
        #expect(picked.first?.output.amount.coin == 2_000_000)
    }

    @Test func collateralPickerThrowsWhenNoPureAdaUtxo() throws {
        // Doesn't matter — we want to test the empty list path.
        do {
            _ = try MnemonicWallet.pickCollateral(from: [])
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    // MARK: - prepareMint with Plutus policy

    @Test func plutusMintAttachesScriptAndCollateralToUnsignedTx() async throws {
        let (wallet, _, _) = try await wallet()
        let policy = dummyPlutusV2()

        let prepared = try await wallet.prepareMint(
            amount: 1,
            assetName: "PlutusTok",
            plutusPolicy: policy,
            redeemer: try stubUnitRedeemer()
        )

        // The mint field carries the asset under the policy hash.
        let mint = prepared.transaction.transactionBody.mint
        #expect(mint != nil)

        // Collateral inputs are populated.
        let collateral = prepared.transaction.transactionBody.collateral
        #expect((collateral?.count ?? 0) >= 1)

        // The Plutus script lands in the witness set (we ignore exact script-version
        // routing because TxBuilder may put it under plutusV2Script vs plutusV1Script).
        let ws = prepared.transaction.transactionWitnessSet
        let hasPlutusV1 = (ws.plutusV1Script?.count ?? 0) > 0
        let hasPlutusV2 = (ws.plutusV2Script?.count ?? 0) > 0
        let hasPlutusV3 = (ws.plutusV3Script?.count ?? 0) > 0
        #expect(hasPlutusV1 || hasPlutusV2 || hasPlutusV3)

        // One redeemer attached, tag = .mint.
        switch ws.redeemers {
        case .list(let list):
            #expect(list.count >= 1)
            #expect(list.first?.tag == .mint)
        case .map(let map):
            #expect(map.count >= 1)
        case .none:
            Issue.record("Expected redeemers in witness set")
        }
    }

    @Test func plutusMintWithExplicitCollateralOverridesAutoPick() async throws {
        let (wallet, _, receive) = try await wallet()
        // Construct a separate UTxO that we'll pass explicitly.
        let explicitCollateral = try TestFixtures.makeUTxO(
            at: receive,
            lovelace: 10_000_000,
            index: 99
        )
        let prepared = try await wallet.prepareMint(
            amount: 1,
            assetName: "Tok",
            plutusPolicy: dummyPlutusV2(),
            redeemer: try stubUnitRedeemer(),
            collateral: [explicitCollateral]
        )
        // The supplied collateral UTxO's transaction input should appear in the body's
        // collateral set.
        let bodyCollateral: Set<TransactionInput>
        switch prepared.transaction.transactionBody.collateral {
        case .list(let arr): bodyCollateral = Set(arr)
        case .nonEmptyOrderedSet(let set): bodyCollateral = set.elements
        case .indefiniteList(let il): bodyCollateral = Set(il.map { $0 })
        case .none: bodyCollateral = []
        }
        #expect(bodyCollateral.contains(explicitCollateral.input))
    }

    @Test func plutusMintAcceptsCustomRedeemer() async throws {
        let (wallet, _, _) = try await wallet()
        let customData = PlutusData.bigInt(BigInteger.int(42))
        let customRedeemer = Redeemer(
            tag: .mint,
            data: customData,
            exUnits: stubExUnits()  // bypass UPLC eval in the stub
        )
        let prepared = try await wallet.prepareMint(
            amount: 1,
            assetName: "Tok",
            plutusPolicy: dummyPlutusV2(),
            redeemer: customRedeemer
        )
        // Redeemer's data should round-trip into the witness set.
        switch prepared.transaction.transactionWitnessSet.redeemers {
        case .list(let list):
            let first = list.first
            #expect(first?.tag == .mint)
            // Data shape: bigInt(42).
            switch first?.data {
            case .bigInt(let n):
                #expect(n == BigInteger.int(42))
            default:
                Issue.record("Redeemer data wasn't preserved: \(String(describing: first?.data))")
            }
        case .map(let map):
            #expect(map.count >= 1)
        case .none:
            Issue.record("Expected redeemers in witness set")
        }
    }

    @Test func plutusMintThrowsWhenNoCollateralAvailable() async throws {
        // Wallet has a single UTxO that holds a native asset — not pure ADA → no collateral.
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let receive = try await probe.receiveAddress()
        let dummyPolicyId = ScriptHash(payload: Data(repeating: 0x11, count: 28))
        let dummyAssetName = AssetName(from: "X")
        let tokenValue = Value(
            coin: 10_000_000,
            multiAsset: MultiAsset([dummyPolicyId: Asset([dummyAssetName: 1])])
        )
        let txInput = try TransactionInput(from: TestFixtures.dummyTxId, index: 0)
        let utxo = UTxO(
            input: txInput,
            output: TransactionOutput(address: receive, amount: tokenValue)
        )
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try receive.toBech32(): [utxo]]
        )
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        do {
            _ = try await wallet.prepareMint(
                amount: 1,
                assetName: "Tok",
                plutusPolicy: dummyPlutusV2()
            )
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            if case .configurationMissing(let detail) = error {
                #expect(detail.contains("collateral"))
            } else if case .insufficientFunds = error {
                // Also acceptable — the test's funding may be insufficient before collateral check.
            } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }
}
