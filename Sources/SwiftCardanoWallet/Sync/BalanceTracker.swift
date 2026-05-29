import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// Tracks UTxOs and balance for a single CIP-1852 ``Account`` across both `external` and
/// `change` roles, up to a configurable gap limit.
///
/// On the first call to ``utxos()`` or ``balance()``, runs an initial sweep
/// (``refresh()``). Subsequent calls return cached results until the next ``refresh()``.
///
/// PR 9 keeps the sweep naive: walk indices `0..<gapLimit` for each role and query the chain
/// for each. Future PRs may parallelize and / or grow the search dynamically when a non-empty
/// trailing window suggests more active addresses exist.
public actor BalanceTracker {

    public let account: Account
    private let keyManager: KeyManager
    private let chainContext: any ChainContext
    private let store: UTxOStore
    public let gapLimit: UInt32

    private var hasRefreshed: Bool = false

    /// Memoized address → payment path map. Lazily filled on first ``paymentPath(for:)``
    /// call; covers the entire `external` + `change` × `0..<gapLimit` matrix the sweep
    /// already walks, so every address the tracker holds UTxOs for is resolvable.
    private var pathByAddress: [Address: DerivationPath]?

    public init(
        account: Account,
        keyManager: KeyManager,
        chainContext: any ChainContext,
        store: UTxOStore = InMemoryUTxOStore(),
        gapLimit: UInt32 = 20
    ) {
        self.account = account
        self.keyManager = keyManager
        self.chainContext = chainContext
        self.store = store
        self.gapLimit = gapLimit
    }

    // MARK: - Sweeping

    /// Pull a fresh snapshot from the chain for every derived address up to ``gapLimit``,
    /// across the `external` and `change` roles, and replace the store entries for each.
    public func refresh() async throws {
        for role in [DerivationPath.Role.external, .change] {
            for index in 0..<gapLimit {
                let address = try await account.address(
                    with: keyManager,
                    role: role,
                    index: index
                )
                let utxos: [UTxO]
                do {
                    utxos = try await chainContext.utxos(address: address)
                } catch {
                    throw WalletError.wrappingProvider(error)
                }
                try await store.upsert(utxos, for: address)
            }
        }
        hasRefreshed = true
    }

    // MARK: - Reads

    /// Every UTxO currently held across all tracked addresses.
    public func utxos() async throws -> [UTxO] {
        try await ensureRefreshed()
        var all: [UTxO] = []
        for address in try await store.allAddresses() {
            all.append(contentsOf: try await store.utxos(for: address))
        }
        return all
    }

    /// UTxOs at a specific address. Triggers an initial refresh if one hasn't run yet.
    public func utxos(at address: Address) async throws -> [UTxO] {
        try await ensureRefreshed()
        return try await store.utxos(for: address)
    }

    /// All addresses currently in the cache. Triggers an initial refresh if needed.
    public func allTrackedAddresses() async throws -> [Address] {
        try await ensureRefreshed()
        return try await store.allAddresses()
    }

    /// Aggregate balance: lovelace, multi-asset, rewards (from `stakeAddressInfo`), UTxO count.
    public func balance() async throws -> WalletBalance {
        let utxos = try await self.utxos()
        let lovelace = utxos.reduce(0) { $0 + $1.output.amount.coin }
        var assets = MultiAsset([:])
        for u in utxos {
            assets += u.output.amount.multiAsset
        }

        let rewardAddr = try await account.rewardAddress(with: keyManager)
        let rewards: Int64
        do {
            let info = try await chainContext.stakeAddressInfo(address: rewardAddr)
            rewards = info.first?.rewardAccountBalance ?? 0
        } catch {
            // Stake address not registered (or backend doesn't support the call) — report 0.
            rewards = 0
        }

        return WalletBalance(
            lovelace: lovelace,
            multiAsset: assets,
            rewards: rewards,
            utxoCount: utxos.count
        )
    }

    // MARK: - Path resolution

    /// Reverse-lookup a payment path for an address the tracker has previously derived.
    ///
    /// Walks both `external` and `change` roles up to `gapLimit` once, caches the result,
    /// and returns the matching `DerivationPath` (or `nil` if `address` doesn't belong to
    /// this wallet's account). Used by ``MnemonicWallet/prepareSend(lovelace:to:)`` to map
    /// each selected input UTxO back to the signing path that owns it.
    public func paymentPath(for address: Address) async throws -> DerivationPath? {
        let map = try await ensurePathMap()
        return map[address]
    }

    /// Bulk variant — useful when callers have a set of addresses (e.g. the unique input
    /// addresses of a freshly built tx) and want to avoid one round-trip per lookup.
    public func paymentPaths(for addresses: Set<Address>) async throws -> [Address: DerivationPath] {
        let map = try await ensurePathMap()
        return map.filter { addresses.contains($0.key) }
    }

    // MARK: - Internals

    private func ensureRefreshed() async throws {
        if !hasRefreshed {
            try await refresh()
        }
    }

    private func ensurePathMap() async throws -> [Address: DerivationPath] {
        if let cached = pathByAddress { return cached }
        var map: [Address: DerivationPath] = [:]
        for role in [DerivationPath.Role.external, .change] {
            for index in 0..<gapLimit {
                let path = account.paymentPath(role: role, index: index)
                let addr = try await account.address(
                    with: keyManager,
                    role: role,
                    index: index
                )
                map[addr] = path
            }
        }
        pathByAddress = map
        return map
    }
}
