import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoTxBuilder

extension MnemonicWallet {

    /// Build (but do not sign or submit) a transaction sending `lovelace` to `to`.
    ///
    /// - Parameters:
    ///   - lovelace: the amount, in lovelace, to send.
    ///   - to: destination address.
    /// - Returns: a ``PreparedTransaction`` that can be signed and submitted (or exported).
    public func prepareSend(lovelace: Int64, to address: Address) async throws -> PreparedTransaction {
        let change = try await changeAddress()

        let context = chainContextHandle()
        let utxoList = try await utxos()

        guard !utxoList.isEmpty else {
            throw WalletError.insufficientFunds(required: UInt64(lovelace), available: 0)
        }

        // Fee estimation needs a witness count *before* coin selection runs, but we won't
        // know which addresses contributed inputs until after `build()`. Use a small
        // upper bound: the count of unique addresses across the candidate set, capped at
        // 4. Real sends almost always consume 1–2 inputs from 1–2 addresses; the cap
        // prevents wallets with funds spread across all 40 (`gapLimit × 2`) tracked
        // addresses from over-paying ~4,000 lovelace per send. If a future caller actually
        // needs to spend from >4 distinct addresses in one tx, they can build a
        // `PreparedTransaction` directly via `TxBuilder` and skip this helper.
        let candidateAddresses = Set(utxoList.map(\.output.address))
        let witnessOverrideCap = 4
        let builder = TxBuilder(context: context)
        builder.witnessOverride = max(1, min(candidateAddresses.count, witnessOverrideCap))

        // Hand the tracker's full UTxO set to TxBuilder as candidates so coin selection picks
        // the minimal subset rather than forcing every cached UTxO into the tx.
        builder.potentialInputs = utxoList

        try builder.addOutput(
            TransactionOutput(address: address, amount: Value(coin: lovelace))
        )

        let body: TransactionBody
        do {
            body = try await builder.build(changeAddress: change)
        } catch {
            // surface insufficient-funds the way callers expect
            let total = utxoList.reduce(0) { $0 + $1.output.amount.coin }
            if total < lovelace {
                throw WalletError.insufficientFunds(
                    required: UInt64(lovelace),
                    available: UInt64(max(0, total))
                )
            }
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

        // Map each chosen input back to the address it was held at, then resolve each
        // address to its payment derivation path. Need one signing path per unique address
        // — a single witness covers every input from that address.
        let signingPaths = try await derivePaymentPaths(
            forInputs: body.inputs.asArray,
            candidates: utxoList
        )

        return PreparedTransaction(
            transaction: unsigned,
            signingPaths: signingPaths,
            chainContext: context,
            keyManager: keyManager
        )
    }

    /// One Web of Trust between coin selection and signing: figure out which addresses the
    /// chosen inputs came from, then ask the ``BalanceTracker`` for their derivation paths.
    /// Throws if any input can't be resolved (paranoid; shouldn't happen in practice
    /// because `potentialInputs` are tracker-derived).
    private func derivePaymentPaths(
        forInputs inputs: [TransactionInput],
        candidates: [UTxO]
    ) async throws -> [DerivationPath] {
        // Build a quick (input → address) map across all candidates. A canonical input is
        // (txId, index); the same UTxO can't appear twice in the candidate list.
        let addressByInput: [TransactionInput: Address] = candidates.reduce(into: [:]) {
            $0[$1.input] = $1.output.address
        }

        // Unique addresses contributing to this tx.
        var uniqueAddresses: Set<Address> = []
        for input in inputs {
            guard let address = addressByInput[input] else {
                throw WalletError.signingFailed(
                    "Selected input \(input) is not in the wallet's tracked UTxO set."
                )
            }
            uniqueAddresses.insert(address)
        }

        // Empty inputs would mean a degenerate / impossible tx — but defend anyway.
        guard !uniqueAddresses.isEmpty else {
            return [account.paymentPath(role: .external, index: 0)]
        }

        let tracker = balanceTracker()
        let pathMap = try await tracker.paymentPaths(for: uniqueAddresses)
        var paths: [DerivationPath] = []
        for addr in uniqueAddresses {
            guard let path = pathMap[addr] else {
                throw WalletError.signingFailed(
                    "Cannot resolve derivation path for input address \(try addr.toBech32())."
                )
            }
            paths.append(path)
        }
        return paths
    }

    /// One-shot: build, sign, submit. Returns the transaction id reported by the chain backend.
    @discardableResult
    public func send(lovelace: Int64, to address: Address) async throws -> String {
        let prepared = try await prepareSend(lovelace: lovelace, to: address)
        let signed = try await prepared.sign()
        return try await signed.submit()
    }
}
