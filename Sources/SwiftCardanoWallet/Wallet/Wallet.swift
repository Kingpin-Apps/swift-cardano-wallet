import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// A wallet observable / signable through one chain provider and one ``KeyManager``.
///
/// Concrete impls in v0.1.0:
/// - ``MnemonicWallet`` (PR 3)
/// - `WatchOnlyWallet` (PR 5)
/// - `HardwareWallet` (PR 13)
///
/// ``MultisigWallet`` (PR 11) is intentionally a sibling type rather than a `Wallet`
/// conformer: it has no single account / keyManager and exposes a different signing
/// flow (``PartialWitness`` / ``PreparedMultisigTransaction``).
public protocol Wallet: Sendable {
    var network: Network { get }
    var account: Account { get }
    var kind: WalletKind { get }
    var keyManager: KeyManager { get }

    /// Next unused payment address (role 0). For PR 3 this is index 0;
    /// gap-limit address sweeping comes in PR 9.
    func receiveAddress() async throws -> Address

    /// Next unused change address (role 1). Same caveat as ``receiveAddress``.
    func changeAddress() async throws -> Address

    /// Reward / stake address (role 2).
    func rewardAddress() async throws -> Address

    /// All UTxOs currently held at the receive address.
    /// PR 9 will widen this to all derived addresses up to the gap limit.
    func utxos() async throws -> [UTxO]

    /// Aggregate balance across the same address set ``utxos()`` covers.
    func balance() async throws -> WalletBalance
}
