import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SystemPackage

public enum ProviderFactory {
    /// Materialize a ``ProviderConfig`` into a live ``ChainContext``.
    public static func make(_ config: ProviderConfig) async throws -> any ChainContext {
        switch config {
        case .offline(let path, let network):
            return try OfflineTransferChainContext(
                filePath: FilePath(path),
                network: network
            )

        case .blockfrost(let projectId, let network):
            return try await BlockFrostChainContext(
                projectId: projectId,
                network: network
            )

        case .koios(let network, let apiKey):
            return try await KoiosChainContext(
                apiKey: apiKey,
                network: network
            )

        case .custom(let make):
            return try await make()
        }
    }
}
