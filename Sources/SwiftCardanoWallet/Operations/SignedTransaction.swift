import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// A fully-witnessed `Transaction`, ready to broadcast.
public struct SignedTransaction: Sendable {
    public let transaction: Transaction
    public let chainContext: any ChainContext

    public init(transaction: Transaction, chainContext: any ChainContext) {
        self.transaction = transaction
        self.chainContext = chainContext
    }

    /// CBOR encoding of the signed transaction.
    public func exportCBOR() -> Data {
        transaction.payload
    }

    /// On-chain transaction id (computed from the body hash).
    public var id: TransactionId? {
        transaction.id
    }

    /// Submit the transaction to the chain backend. Returns the transaction id as reported
    /// by the backend.
    @discardableResult
    public func submit() async throws -> String {
        do {
            return try await chainContext.submitTx(tx: .transaction(transaction))
        } catch {
            throw WalletError.wrappingSubmit(error)
        }
    }
}
