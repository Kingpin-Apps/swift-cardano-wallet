import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoCIPs

/// Build a CIP-30 provider for a ``MnemonicWallet``.
///
/// `swift-cardano-cips` ships a reference ``KeyStoreCIP30Provider`` that handles the spec
/// details correctly:
/// - Gates `signTx`, `signData`, and `submitTx` on a ``CIP30ApprovalPolicy`` so a connected
///   dApp can't sign arbitrary transactions without user consent.
/// - Honours `partialSign: false` by checking required-signer hashes against the wallet's
///   keys and throwing ``TxSignError/proofGeneration(_:)`` when any are missing.
/// - Signs CIP-8 payloads as raw bytes via ``SwiftCardanoCIPs/CIP8/sign(payload:signingKey:attachCoseKey:network:)`` —
///   no UTF-8 transcoding, so the signed message is exactly what the dApp supplied.
/// - Emits the stake-key witness only when the transaction body actually needs it.
///
/// This file wires the wallet's role-0 payment + stake keys into that provider and adapts
/// the wallet's underlying ``SwiftCardanoChain/ChainContext`` to ``CIP30DataSource``.
///
/// **Surface scope.** The returned provider is single-address: only the role-0 / index-0
/// derivation is exposed via `getUsedAddresses` / `getChangeAddress`. Other addresses the
/// wallet's ``BalanceTracker`` may know about (gap-limit sweep) are deliberately hidden
/// from dApps; CIP-30 is the external surface, not the wallet's internal HD view.
extension MnemonicWallet {

    /// Build a CIP-30 provider scoped to this wallet's role-0 keys.
    ///
    /// - Parameters:
    ///   - info: Wallet metadata advertised via the initial API (name, icon, version).
    ///   - policy: Per-operation approval gate. Required — no default. Use
    ///     ``SwiftCardanoCIPs/CIP30ApprovalPolicy/denyAll`` as a safe placeholder, or
    ///     ``SwiftCardanoCIPs/CIP30ApprovalPolicy/allowAll`` for tests and developer harnesses.
    ///   - dataSource: Optional explicit ``CIP30DataSource``. Defaults to an in-process
    ///     adapter over the wallet's ``MnemonicWallet/chainContextHandle()``.
    ///   - grantedExtensions: Extensions the provider should advertise via `getExtensions()`.
    /// - Returns: A ``SwiftCardanoCIPs/KeyStoreCIP30Provider`` ready to be bridged to a dApp.
    public func cip30Provider(
        info: WalletInfo,
        policy: CIP30ApprovalPolicy,
        dataSource: CIP30DataSource? = nil,
        grantedExtensions: [Extension] = []
    ) async throws -> KeyStoreCIP30Provider {
        let paymentSkey = try await keyManager.paymentSigningKeyType(
            at: account.paymentPath(role: .external, index: 0)
        )
        // Stake key is optional — wallets without a stake key still produce a usable
        // CIP-30 provider, just without reward-address support.
        let stakeSkey: SigningKeyType?
        do {
            stakeSkey = try await keyManager.stakeSigningKeyType(at: account.stakePath())
        } catch {
            stakeSkey = nil
        }

        let resolvedDataSource = dataSource ?? ChainContextDataSource(context: chainContextHandle())

        return try KeyStoreCIP30Provider(
            info: info,
            paymentKey: paymentSkey,
            stakeKey: stakeSkey,
            network: network,
            dataSource: resolvedDataSource,
            grantedExtensions: grantedExtensions,
            policy: policy
        )
    }
}

/// Adapts ``SwiftCardanoChain/ChainContext`` to ``CIP30DataSource`` so any wallet chain
/// backend (Blockfrost, Koios, Ogmios, offline, custom) automatically works as a CIP-30
/// data source.
struct ChainContextDataSource: CIP30DataSource {
    let context: any ChainContext

    func utxos(for address: Address) async throws -> [UTxO] {
        try await context.utxos(address: address)
    }

    func submit(_ tx: Data) async throws -> String {
        try await context.submitTxCBOR(cbor: tx)
    }
}
