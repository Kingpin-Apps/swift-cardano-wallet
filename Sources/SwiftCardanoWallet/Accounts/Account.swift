import Foundation
import SwiftCardanoCore

/// A CIP-1852 account view: payment + change + stake derivation rooted at a single
/// `account` index, on one network. Combine with a ``KeyManager`` to materialize addresses.
public struct Account: Sendable, Equatable {
    public let index: UInt32
    public let network: Network
    public let purpose: UInt32

    public init(
        index: UInt32 = 0,
        network: Network,
        purpose: UInt32 = DerivationPath.standardPurpose
    ) {
        self.index = index
        self.network = network
        self.purpose = purpose
    }

    public func paymentPath(role: DerivationPath.Role = .external, index: UInt32 = 0) -> DerivationPath {
        DerivationPath(purpose: purpose, account: self.index, role: role, index: index)
    }

    public func stakePath(index: UInt32 = 0) -> DerivationPath {
        DerivationPath(purpose: purpose, account: self.index, role: .stake, index: index)
    }
}

extension Account {
    /// Derive a base address (payment + stake) at the given role/index.
    public func address(
        with keyManager: KeyManager,
        role: DerivationPath.Role = .external,
        index: UInt32 = 0,
        stakeIndex: UInt32 = 0
    ) async throws -> Address {
        let pVKey = try await keyManager.paymentVerificationKey(
            at: paymentPath(role: role, index: index)
        )
        let sVKey = try await keyManager.stakeVerificationKey(
            at: stakePath(index: stakeIndex)
        )
        return try Address(
            paymentPart: .verificationKeyHash(try pVKey.hash()),
            stakingPart: .verificationKeyHash(try sVKey.hash()),
            network: network.networkId
        )
    }

    /// Reward (stake) address — used for delegation, withdrawals.
    public func rewardAddress(
        with keyManager: KeyManager,
        stakeIndex: UInt32 = 0
    ) async throws -> Address {
        let sVKey = try await keyManager.stakeVerificationKey(
            at: stakePath(index: stakeIndex)
        )
        return try Address(
            stakingPart: .verificationKeyHash(try sVKey.hash()),
            network: network.networkId
        )
    }

    /// Enterprise address — payment-only, no staking.
    public func enterpriseAddress(
        with keyManager: KeyManager,
        role: DerivationPath.Role = .external,
        index: UInt32 = 0
    ) async throws -> Address {
        let pVKey = try await keyManager.paymentVerificationKey(
            at: paymentPath(role: role, index: index)
        )
        return try Address(
            paymentPart: .verificationKeyHash(try pVKey.hash()),
            network: network.networkId
        )
    }
}
