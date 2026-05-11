import Foundation
import OrderedCollections
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

extension MnemonicWallet {

    /// Build (unsigned) a transaction that mints `amount` of `assetName` under a **Plutus**
    /// minting policy. Plutus scripts require:
    ///
    /// - A **redeemer** that the script consumes when validating the mint. Defaults to a
    ///   ``SwiftCardanoCore/PlutusData/Unit`` constructor (`0()`) — sufficient for scripts
    ///   that ignore their redeemer.
    /// - **Collateral UTxOs** that get burned if the script fails on-chain. We auto-pick
    ///   one small ADA-only UTxO from the wallet by default; pass `collateral: [...]` to
    ///   override.
    /// - **Execution units** estimating CPU + memory cost of evaluating the script. If the
    ///   supplied redeemer has `exUnits == nil`, ``SwiftCardanoTxBuilder/TxBuilder``
    ///   auto-estimates by simulating the script during `build()`. If you've already run
    ///   evaluation off-chain, set `exUnits` on the redeemer to skip simulation.
    ///
    /// - Parameters:
    ///   - amount: Number of asset units to mint. Negative values **burn**.
    ///   - assetName: UTF-8 string for the asset name (≤ 32 bytes once encoded).
    ///   - plutusPolicy: A ``SwiftCardanoCore/PlutusScript`` (any of V1 / V2 / V3) compiled
    ///     to raw CBOR bytes.
    ///   - redeemer: Optional ``SwiftCardanoCore/Redeemer``. When `nil`, a Unit redeemer
    ///     with auto-estimated execution units is used. When supplied, `redeemer.tag` is
    ///     forced to `.mint` by `TxBuilder`.
    ///   - to: Destination for the freshly-minted asset. Defaults to the wallet's receive
    ///     address. Ignored when `amount < 0` (burn).
    ///   - minOutputLovelace: Lovelace included in the asset output. Default 2 ADA.
    ///   - metadata: Optional CIP-25-style metadata map keyed by label.
    ///   - collateral: Optional pre-selected collateral UTxOs. If `nil`, the wallet picks
    ///     a single ADA-only UTxO ≥ 5 ADA; throws ``WalletError/configurationMissing(_:)``
    ///     if no suitable UTxO is available.
    ///   - additionalSigningPaths: Extra ``DerivationPath``s required by the policy
    ///     (besides the wallet's role-0 payment key, which is always added).
    public func prepareMint(
        amount: Int,
        assetName: String,
        plutusPolicy: PlutusScript,
        redeemer: Redeemer? = nil,
        to: Address? = nil,
        minOutputLovelace: Int = 2_000_000,
        metadata: [TransactionMetadatumLabel: TransactionMetadatum]? = nil,
        collateral: [UTxO]? = nil,
        additionalSigningPaths: [DerivationPath] = []
    ) async throws -> PreparedTransaction {
        guard amount != 0 else {
            throw WalletError.unsupportedOperation("Mint amount cannot be zero")
        }

        let context = chainContextHandle()
        let change = try await changeAddress()
        let recipient: Address
        if let to {
            recipient = to
        } else {
            recipient = try await receiveAddress()
        }

        // Map the Plutus enum into the broader `ScriptType` the txbuilder accepts.
        let scriptType: ScriptType
        switch plutusPolicy {
        case .plutusV1Script(let s): scriptType = .plutusV1Script(s)
        case .plutusV2Script(let s): scriptType = .plutusV2Script(s)
        case .plutusV3Script(let s): scriptType = .plutusV3Script(s)
        }

        let policyId: ScriptHash
        let assetNameStruct: AssetName
        let mintMultiAsset: MultiAsset
        do {
            policyId = try scriptHash(script: scriptType)
            assetNameStruct = AssetName(from: assetName)
            mintMultiAsset = MultiAsset([
                policyId: Asset([assetNameStruct: amount])
            ])
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let auxiliaryData: AuxiliaryData?
        if let metadata {
            do {
                let meta = try Metadata(metadata)
                auxiliaryData = AuxiliaryData(data: .metadata(meta))
            } catch {
                throw WalletError.wrappingValidation(error)
            }
        } else {
            auxiliaryData = nil
        }

        let utxos = try await self.utxos()
        guard !utxos.isEmpty else {
            throw WalletError.insufficientFunds(required: UInt64(minOutputLovelace), available: 0)
        }

        // Default redeemer: unit constructor `0()`, with nil exUnits so TxBuilder
        // auto-estimates during build.
        let effectiveRedeemer: Redeemer
        if let redeemer {
            effectiveRedeemer = redeemer
        } else {
            do {
                let unitData = try Unit().toPlutusData()
                effectiveRedeemer = Redeemer(tag: .mint, data: unitData)
            } catch {
                throw WalletError.wrappingValidation(error)
            }
        }

        // Auto-pick collateral if the caller didn't provide one.
        let selectedCollateral: [UTxO]
        if let collateral {
            selectedCollateral = collateral
        } else {
            selectedCollateral = try Self.pickCollateral(from: utxos)
        }

        let totalSigners = 1 + additionalSigningPaths.count
        let builder = TxBuilder(context: context)
        builder.witnessOverride = totalSigners
        builder.mint = mintMultiAsset
        builder.auxiliaryData = auxiliaryData
        builder.potentialInputs = utxos
        builder.collaterals = selectedCollateral

        do {
            _ = try builder.addMintingScript(
                .script(scriptType),
                redeemer: effectiveRedeemer
            )
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        if amount > 0 {
            let outValue = Value(coin: minOutputLovelace, multiAsset: mintMultiAsset)
            do {
                try builder.addOutput(TransactionOutput(address: recipient, amount: outValue))
            } catch {
                throw WalletError.wrappingValidation(error)
            }
        }

        let body: TransactionBody
        do {
            body = try await builder.build(changeAddress: change)
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let witnessSet: TransactionWitnessSet
        do {
            witnessSet = try builder.buildWitnessSet()
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let unsigned = Transaction(
            transactionBody: body,
            transactionWitnessSet: witnessSet,
            auxiliaryData: builder.auxiliaryData
        )

        let signingPaths: [DerivationPath] = [
            account.paymentPath(role: .external, index: 0)
        ] + additionalSigningPaths

        return PreparedTransaction(
            transaction: unsigned,
            signingPaths: signingPaths,
            chainContext: context,
            keyManager: keyManager
        )
    }

    /// Pick a single ADA-only UTxO with at least 5 ADA — the conventional collateral
    /// amount for Plutus mints. Falls back to "any pure-ADA UTxO" if none reach 5 ADA so
    /// small testnets don't get stuck.
    ///
    /// Throws ``WalletError/configurationMissing(_:)`` if the wallet has no pure-ADA UTxO
    /// at all. Callers in that situation should fund the wallet with a collateral UTxO
    /// first, or pass an explicit `collateral:` array to ``prepareMint(...)``.
    static func pickCollateral(from utxos: [UTxO]) throws -> [UTxO] {
        let adaOnly = utxos.filter { $0.output.amount.multiAsset.data.isEmpty }
        guard !adaOnly.isEmpty else {
            throw WalletError.configurationMissing(
                "No pure-ADA UTxO available for Plutus collateral. Plutus mints require a UTxO with no native assets attached."
            )
        }
        // Prefer the smallest UTxO ≥ 5 ADA (5_000_000 lovelace).
        let preferred = adaOnly
            .filter { $0.output.amount.coin >= 5_000_000 }
            .sorted { $0.output.amount.coin < $1.output.amount.coin }
        if let first = preferred.first {
            return [first]
        }
        // Fall back to the largest pure-ADA UTxO we have — fees + collateral come out of
        // the same wallet, so this is best-effort. Caller may need to override.
        let largest = adaOnly.max { $0.output.amount.coin < $1.output.amount.coin }
        return largest.map { [$0] } ?? []
    }

    // MARK: - One-shot helper

    /// Build, sign, and submit a Plutus-policy mint in one call.
    @discardableResult
    public func mint(
        amount: Int,
        assetName: String,
        plutusPolicy: PlutusScript,
        redeemer: Redeemer? = nil,
        to: Address? = nil,
        minOutputLovelace: Int = 2_000_000,
        metadata: [TransactionMetadatumLabel: TransactionMetadatum]? = nil,
        collateral: [UTxO]? = nil,
        additionalSigningPaths: [DerivationPath] = []
    ) async throws -> String {
        try await prepareMint(
            amount: amount,
            assetName: assetName,
            plutusPolicy: plutusPolicy,
            redeemer: redeemer,
            to: to,
            minOutputLovelace: minOutputLovelace,
            metadata: metadata,
            collateral: collateral,
            additionalSigningPaths: additionalSigningPaths
        ).sign().submit()
    }
}
