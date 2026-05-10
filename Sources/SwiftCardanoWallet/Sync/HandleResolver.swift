import Foundation
import SwiftCardanoCore
import SwiftHandlesAPI

/// Resolves an ADA Handle (`$alice`, `$alice.subhandle`, …) into a Cardano `Address`.
///
/// Defined as a protocol so callers can inject a mock resolver in tests, or swap the
/// default Handle.me-backed implementation for a self-hosted proxy or a different
/// upstream resolver.
public protocol HandleResolver: Sendable {

    /// Resolve a single handle. Implementations should accept both `"alice"` and
    /// `"$alice"` (the leading `$` is the canonical user-facing form).
    func resolve(_ handle: String) async throws -> Address

    /// Drop any cached entries. Default impl is a no-op for stateless resolvers.
    func clearCache() async
}

extension HandleResolver {
    public func clearCache() async {}
}

/// Default `HandleResolver` backed by [handle.me](https://handle.me)'s public API via
/// `swift-handles-api`.
///
/// **Network constraint:** the upstream API is mainnet-only. Constructing this resolver
/// for any other network throws ``WalletError/configurationMissing(_:)``.
///
/// Resolved addresses are cached in-memory with a configurable TTL (default 5 minutes) so
/// repeat lookups inside a single user session don't hammer the API. The cache is purely
/// in-process; restart the app and you'll re-fetch.
public actor DefaultHandleResolver: HandleResolver {

    private struct CacheEntry {
        let address: Address
        let expiresAt: Date
    }

    private let handles: Handles
    private let ttl: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private let clock: @Sendable () -> Date

    /// Construct a resolver against `network`. Only `.mainnet` is supported today (the
    /// upstream API doesn't expose other networks); pass any other network and this init
    /// will throw.
    ///
    /// - Parameters:
    ///   - network: Wallet network. Must be `.mainnet`.
    ///   - apiKey: Optional handle.me API key. Without a key the API still responds but
    ///     enforces strict rate limits.
    ///   - ttl: How long resolved addresses stay in cache. Default 5 minutes — short enough
    ///     to pick up handle ownership changes in the same session, long enough to absorb
    ///     bursts in a UI.
    public init(
        network: Network,
        apiKey: String? = nil,
        ttl: TimeInterval = 300
    ) throws {
        try self.init(
            network: network,
            apiKey: apiKey,
            ttl: ttl,
            clock: { Date() }
        )
    }

    /// Test-friendly init exposing a clock injection point so caches can be aged
    /// deterministically without `Task.sleep`.
    internal init(
        network: Network,
        apiKey: String? = nil,
        ttl: TimeInterval = 300,
        clock: @Sendable @escaping () -> Date
    ) throws {
        guard network == .mainnet else {
            throw WalletError.configurationMissing(
                "DefaultHandleResolver only supports mainnet (the upstream API does not expose \(network))."
            )
        }
        do {
            self.handles = try Handles(network: .mainnet, apiKey: apiKey)
        } catch {
            throw WalletError.configurationMissing("Failed to construct Handles client: \(error)")
        }
        self.ttl = ttl
        self.clock = clock
    }

    /// Resolve a handle. On a cache miss, hits the upstream API and caches the result.
    public func resolve(_ handle: String) async throws -> Address {
        let normalized = Self.normalize(handle)
        guard !normalized.isEmpty else {
            throw WalletError.handleNotFound(handle)
        }

        if let entry = cache[normalized], entry.expiresAt > clock() {
            return entry.address
        }

        let address = try await fetchUncached(normalized)
        cache[normalized] = CacheEntry(
            address: address,
            expiresAt: clock().addingTimeInterval(ttl)
        )
        return address
    }

    public func clearCache() {
        cache.removeAll()
    }

    // MARK: - Internals

    /// Strip the leading `$` and lowercase. The upstream API treats handles
    /// case-insensitively but normalising at the boundary keeps cache keys consistent.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$") { s.removeFirst() }
        return s.lowercased()
    }

    private func fetchUncached(_ normalized: String) async throws -> Address {
        let response: Operations.GetHandlesHandle.Output
        do {
            response = try await handles.client.getHandlesHandle(
                Operations.GetHandlesHandle.Input(path: .init(handle: normalized))
            )
        } catch {
            throw WalletError.providerError("Handle resolver: \(error)")
        }

        let body: Components.Schemas.Handle
        switch response {
        case .ok(let ok):
            do { body = try ok.body.json } catch {
                throw WalletError.providerError("Handle '$\(normalized)' decode error: \(error)")
            }
        case .accepted(let acc):
            // 202 means the API has slightly stale data — still usable for sending.
            do { body = try acc.body.json } catch {
                throw WalletError.providerError("Handle '$\(normalized)' decode error: \(error)")
            }
        case .badRequest:
            throw WalletError.handleNotFound("$\(normalized): bad request")
        case .notFound:
            throw WalletError.handleNotFound("$\(normalized)")
        case .undocumented(statusCode: let code, _):
            throw WalletError.providerError("Handle resolver returned HTTP \(code)")
        }

        // Prefer the explicit `resolved_addresses.ada` pointer (set by the holder when
        // pointing handle to a specific payment address); fall back to `holder` otherwise.
        // The generated Swift names are camelCase per the OpenAPI generator's idiomatic mode.
        let bech32 = body.resolvedAddresses?.ada ?? body.holder
        guard let bech32, !bech32.isEmpty else {
            throw WalletError.handleNotFound(
                "$\(normalized): handle has no resolvable address"
            )
        }

        do {
            return try Address.fromBech32(bech32)
        } catch {
            throw WalletError.providerError(
                "Handle '$\(normalized)' returned unparseable address '\(bech32)': \(error)"
            )
        }
    }
}
