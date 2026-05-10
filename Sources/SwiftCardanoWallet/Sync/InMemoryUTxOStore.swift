import Foundation
import SwiftCardanoCore

/// In-process ``UTxOStore`` backed by a plain dictionary. The default for ``MnemonicWallet`` —
/// no persistence, no dependencies, fast.
public actor InMemoryUTxOStore: UTxOStore {

    private var byAddress: [Address: [UTxO]] = [:]

    public init() {}

    public func upsert(_ utxos: [UTxO], for address: Address) async throws {
        byAddress[address] = utxos
    }

    public func utxos(for address: Address) async throws -> [UTxO] {
        byAddress[address] ?? []
    }

    public func allAddresses() async throws -> [Address] {
        Array(byAddress.keys)
    }

    public func clear() async throws {
        byAddress.removeAll()
    }
}
