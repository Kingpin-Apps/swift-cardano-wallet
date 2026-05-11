import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// Common shape for HD-style wallets backed by a single ``KeyManager`` + ``Account``.
///
/// Conformers in v0.1.0:
/// - ``MnemonicWallet`` — the canonical HD wallet.
///
/// ``MultisigWallet`` and ``HardwareWallet`` are intentionally **not** `WalletProtocol`
/// conformers: each has its own preparation / signing flow (``PartialWitness`` &
/// ``PreparedMultisigTransaction`` for multisig; the manual / driven dance through
/// `cardano-hw-cli` for hardware), and neither has a single ``KeyManager``.
///
/// The top-level ``Wallet`` enum unifies all three concrete types into one Sendable value
/// at the API surface — use that for storage + dispatch, drop down to the conforming
/// concrete type when you need protocol-shape access.
public protocol WalletProtocol: Sendable {
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
