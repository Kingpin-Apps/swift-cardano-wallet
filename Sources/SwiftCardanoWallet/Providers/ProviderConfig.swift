import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SystemPackage

/// Declarative configuration for a chain backend. Resolved into a concrete
/// `any ChainContext` by ``ProviderFactory``.
public enum ProviderConfig: @unchecked Sendable {
    /// Offline JSON transfer file (built on an online machine, ferried via USB).
    case offline(filePath: String, network: Network = .mainnet)

    /// Blockfrost. `projectId` is your `mainnet…` / `preprod…` / `preview…` API key.
    /// Pass `nil` to read it from `BLOCKFROST_PROJECT_ID` env or a config file.
    case blockfrost(projectId: String? = nil, network: Network = .mainnet)

    /// Koios. `apiKey` is optional (Koios is publicly accessible without one for low-volume use).
    case koios(network: Network = .mainnet, apiKey: String? = nil)

    /// Power-user escape hatch: bring your own ChainContext (Ogmios, Kupo, NodeSocket, mock).
    /// The closure runs once during ``Wallet`` construction.
    case custom(make: @Sendable () async throws -> any ChainContext)

    /// The network this provider is targeting — useful for sanity-checking against the wallet's
    /// configured network without spinning up a connection.
    public var network: Network {
        switch self {
        case .offline(_, let network),
             .blockfrost(_, let network),
             .koios(let network, _):
            return network
        case .custom:
            // For custom contexts we trust the caller. Network conflicts (if any)
            // are detected at runtime when the wallet first queries protocol params.
            return .mainnet
        }
    }
}
