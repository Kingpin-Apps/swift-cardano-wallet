import Foundation
import SwiftCardanoCore

/// Pluggable persistent (or in-memory) cache of UTxOs keyed by address.
///
/// ``BalanceTracker`` is the primary writer; consumer code typically only reads.
///
/// Default impls in v0.1.0:
/// - ``InMemoryUTxOStore`` (PR 9, no I/O, lives in-process).
/// - `SQLiteUTxOStore` (PR 10, behind the `SQLite` package trait).
public protocol UTxOStore: Sendable {
    /// Replace the entire UTxO list at `address` with the given snapshot.
    func upsert(_ utxos: [UTxO], for address: Address) async throws

    /// All UTxOs currently cached for `address`. Empty array if the address is unknown.
    func utxos(for address: Address) async throws -> [UTxO]

    /// Every address that's been written via ``upsert(_:for:)`` (even with an empty list).
    func allAddresses() async throws -> [Address]

    /// Drop every cached entry.
    func clear() async throws
}
