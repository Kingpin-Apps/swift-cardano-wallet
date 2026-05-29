import Foundation
import OrderedCollections
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder
import SwiftCardanoCIPs

extension MnemonicWallet {

    // MARK: - Generic mint / burn

    /// Build (unsigned) a transaction that mints `amount` of `assetName` under `policy`.
    ///
    /// - Parameters:
    ///   - amount: Number of asset units to mint. Negative values **burn**.
    ///   - assetName: UTF-8 string for the asset name (≤ 32 bytes once encoded).
    ///   - policy: The native-script minting policy.
    ///   - to: Where to send the freshly-minted asset. Defaults to the wallet's receive address.
    ///         Ignored when `amount < 0` (burns; nothing is created).
    ///   - minOutputLovelace: Lovelace attached to the asset output (must satisfy chain min-UTxO).
    ///         Default 2 ADA — conservative; tighten with `coinsPerUTXOByte` math if you want.
    ///   - metadata: Optional metadata map keyed by label. CIP-25 lives at label 721.
    ///   - additionalSigningPaths: Extra wallet ``DerivationPath``s required by the policy
    ///         (besides the wallet's role-0 payment key, which is always added).
    public func prepareMint(
        amount: Int64,
        assetName: String,
        policy: NativeScript,
        to: Address? = nil,
        minOutputLovelace: Int64 = 2_000_000,
        metadata: [TransactionMetadatumLabel: TransactionMetadatum]? = nil,
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
        let policyId: ScriptHash
        let assetNameStruct: AssetName
        let mintMultiAsset: MultiAsset
        do {
            policyId = try policy.scriptHash()
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

        let totalSigners = 1 + additionalSigningPaths.count
        let builder = TxBuilder(context: context)
        builder.witnessOverride = totalSigners
        builder.mint = mintMultiAsset
        builder.nativeScripts = [policy]
        builder.auxiliaryData = auxiliaryData
        builder.potentialInputs = utxos

        if amount > 0 {
            // Send the minted asset to `recipient` with min-UTxO lovelace alongside.
            let outValue = Value(coin: minOutputLovelace, multiAsset: mintMultiAsset)
            do {
                try builder.addOutput(TransactionOutput(address: recipient, amount: outValue))
            } catch {
                throw WalletError.wrappingValidation(error)
            }
        }
        // For burns (amount < 0) no extra output is required — TxBuilder consumes the asset
        // from `potentialInputs` to satisfy the negative mint balance.

        let body: TransactionBody
        do {
            body = try await builder.build(changeAddress: change)
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let witnessSet: TransactionWitnessSet
        do {
            var ws = try builder.buildWitnessSet()
            // Surface the policy script in the witness set so validators see it.
            ws.nativeScripts = .nonEmptyOrderedSet(NonEmptyOrderedSet([policy]))
            witnessSet = ws
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

    /// Convenience inverse of ``prepareMint(amount:...)``: burns `amount` (positive count)
    /// of `assetName` under `policy`. The wallet must already hold at least `amount` of the
    /// asset, otherwise build will fail at coin-selection.
    public func prepareBurn(
        amount: Int64,
        assetName: String,
        policy: NativeScript,
        additionalSigningPaths: [DerivationPath] = []
    ) async throws -> PreparedTransaction {
        precondition(amount > 0, "burn amount must be positive (it's negated internally)")
        return try await prepareMint(
            amount: -amount,
            assetName: assetName,
            policy: policy,
            additionalSigningPaths: additionalSigningPaths
        )
    }

    // MARK: - One-shot NFT mint (CIP-25)

    /// Build (unsigned) a one-shot NFT mint with CIP-25 metadata. The mint policy is
    /// `ScriptAll([scriptPubkey(<wallet payment key hash>), invalidHereAfter(<ttl>)])` —
    /// after the TTL slot expires the policy can never mint again, making the asset
    /// genuinely one-shot.
    ///
    /// - Parameters:
    ///   - name: Asset name (UTF-8, ≤ 32 bytes once encoded).
    ///   - metadata: CIP-25 NFT metadata.
    ///   - ttlSlotsFromNow: How many slots ahead of the current chain tip the policy stays
    ///         valid. Default `100_000` (≈ 27.7 hours at 1 slot/sec).
    ///   - to: Destination of the new NFT. Defaults to the wallet's receive address.
    public func prepareMintNFT(
        name: String,
        metadata: CIP25NFTMetadata,
        ttlSlotsFromNow: Int = 100_000,
        to: Address? = nil
    ) async throws -> PreparedTransaction {
        let context = chainContextHandle()
        let paymentVKey = try await keyManager.paymentVerificationKey(
            at: account.paymentPath(role: .external, index: 0)
        )
        let keyHash: VerificationKeyHash
        do {
            keyHash = try paymentVKey.hash()
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let lastSlot: Int
        do {
            lastSlot = try await context.lastBlockSlot()
        } catch {
            throw WalletError.wrappingProvider(error)
        }
        let ttlSlot = lastSlot + ttlSlotsFromNow

        let policy = NativeScript.scriptAll(
            ScriptAll(scripts: [
                .scriptPubkey(ScriptPubkey(keyHash: keyHash)),
                .invalidHereAfter(AfterScript(slot: SlotNumber(ttlSlot))),
            ])
        )

        let policyId: ScriptHash
        do {
            policyId = try policy.scriptHash()
        } catch {
            throw WalletError.wrappingValidation(error)
        }

        let cip25 = metadata.encode(policyId: policyId, assetName: name)
        let metaMap: [TransactionMetadatumLabel: TransactionMetadatum] = [
            CIP25_METADATA_LABEL: cip25
        ]

        return try await prepareMint(
            amount: 1,
            assetName: name,
            policy: policy,
            to: to,
            metadata: metaMap
        )
    }

    // MARK: - One-shot helpers

    @discardableResult
    public func mint(
        amount: Int64,
        assetName: String,
        policy: NativeScript,
        to: Address? = nil,
        metadata: [TransactionMetadatumLabel: TransactionMetadatum]? = nil,
        additionalSigningPaths: [DerivationPath] = []
    ) async throws -> String {
        try await prepareMint(
            amount: amount,
            assetName: assetName,
            policy: policy,
            to: to,
            metadata: metadata,
            additionalSigningPaths: additionalSigningPaths
        ).sign().submit()
    }

    @discardableResult
    public func burn(
        amount: Int64,
        assetName: String,
        policy: NativeScript,
        additionalSigningPaths: [DerivationPath] = []
    ) async throws -> String {
        try await prepareBurn(
            amount: amount,
            assetName: assetName,
            policy: policy,
            additionalSigningPaths: additionalSigningPaths
        ).sign().submit()
    }

    @discardableResult
    public func mintNFT(
        name: String,
        metadata: CIP25NFTMetadata,
        ttlSlotsFromNow: Int = 100_000,
        to: Address? = nil
    ) async throws -> String {
        try await prepareMintNFT(
            name: name,
            metadata: metadata,
            ttlSlotsFromNow: ttlSlotsFromNow,
            to: to
        ).sign().submit()
    }

    // MARK: - CIP-14 fingerprint helper

    /// CIP-14 asset fingerprint (`asset1...` bech32). Useful for displaying assets in UI.
    public nonisolated func assetFingerprint(policyId: ScriptHash, assetName: AssetName) throws -> String {
        guard let fp = try CIP14.encodeAsset(
            policyId: .policyId(PolicyID(payload: policyId.payload)),
            assetName: .assetName(assetName)
        ) else {
            throw WalletError.wrappingValidation(
                NSError(domain: "CIP14", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "Bech32 encoding returned nil for asset fingerprint",
                ])
            )
        }
        return fp
    }
}
