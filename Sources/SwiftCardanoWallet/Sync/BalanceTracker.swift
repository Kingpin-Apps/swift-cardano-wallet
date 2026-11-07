import Foundation
import SwiftCardanoCore
import SwiftCardanoChain

/// Tracks UTxOs and balance for a single CIP-1852 ``Account`` across both `external` and
/// `change` roles, up to a configurable gap limit.
///
/// On the first call to ``utxos()`` or ``balance()``, runs an initial sweep
/// (``refresh()``). Subsequent calls return cached results until the next ``refresh()``.
///
/// The sweep follows the BIP-44 gap rule per role: it keeps deriving addresses until it has
/// seen `gapLimit` consecutive empty ones after the last address holding UTxOs, up to
/// ``maxAddressIndex``. Reads only return UTxOs at addresses this account derived, even when
/// the ``UTxOStore`` is shared with other accounts.
public actor BalanceTracker {

    public let account: Account
    private let keyManager: KeyManager
    private let chainContext: any ChainContext
    private let store: UTxOStore
    /// Consecutive empty addresses per role that end the sweep. Always at least 1.
    public let gapLimit: UInt32
    /// Highest address index (exclusive) the sweep will derive per role, whatever the
    /// provider reports. Bounds the work a provider can cause.
    public let maxAddressIndex: UInt32

    private var hasRefreshed: Bool = false

    /// Number of indices the last sweep covered per role. Starts at ``gapLimit``.
    private var scannedCount: [DerivationPath.Role: UInt32] = [:]

    /// Memoized address → payment path map. Covers every address the sweep has derived
    /// (`external` + `change` × `0..<scannedCount`), so every address the tracker holds
    /// UTxOs for is resolvable.
    private var pathByAddress: [Address: DerivationPath]?

    public init(
        account: Account,
        keyManager: KeyManager,
        chainContext: any ChainContext,
        store: UTxOStore = InMemoryUTxOStore(),
        gapLimit: UInt32 = 20,
        maxAddressIndex: UInt32 = 10_000
    ) {
        self.account = account
        self.keyManager = keyManager
        self.chainContext = chainContext
        self.store = store
        self.gapLimit = max(1, gapLimit)
        self.maxAddressIndex = max(self.gapLimit, maxAddressIndex)
    }

    // MARK: - Sweeping

    /// Pull a fresh snapshot from the chain for every derived address across the `external`
    /// and `change` roles, and replace the store entries for each. Each role is scanned until
    /// ``gapLimit`` consecutive addresses hold nothing (never fewer than ``gapLimit`` indices,
    /// never more than ``maxAddressIndex``).
    public func refresh() async throws {
        var map = pathByAddress ?? [:]
        for role in [DerivationPath.Role.external, .change] {
            let previous = scannedCount[role] ?? gapLimit
            var end = gapLimit
            var index: UInt32 = 0
            while index < end || index < previous {
                let address = try await account.address(
                    with: keyManager,
                    role: role,
                    index: index
                )
                map[address] = account.paymentPath(role: role, index: index)
                let utxos: [UTxO]
                do {
                    utxos = try await chainContext.utxos(address: address)
                } catch {
                    throw WalletError.wrappingProvider(error)
                }
                try await store.upsert(utxos, for: address)
                if !utxos.isEmpty {
                    end = min(maxAddressIndex, max(end, index + 1 + gapLimit))
                }
                index += 1
            }
            scannedCount[role] = index
        }
        pathByAddress = map
        hasRefreshed = true
    }

    // MARK: - Reads

    /// Every UTxO currently held across this account's tracked addresses. Store entries for
    /// addresses this account didn't derive (a store shared with other accounts) are skipped.
    public func utxos() async throws -> [UTxO] {
        var all: [UTxO] = []
        for address in try await allTrackedAddresses() {
            all.append(contentsOf: try await store.utxos(for: address))
        }
        return all
    }

    /// UTxOs at a specific address. Triggers an initial refresh if one hasn't run yet.
    public func utxos(at address: Address) async throws -> [UTxO] {
        try await ensureRefreshed()
        return try await store.utxos(for: address)
    }

    /// This account's addresses currently in the cache. Triggers an initial refresh if needed.
    public func allTrackedAddresses() async throws -> [Address] {
        try await ensureRefreshed()
        let own = try await ensurePathMap()
        return try await store.allAddresses().filter { own[$0] != nil }
    }

    /// Aggregate balance: lovelace, multi-asset, rewards (from `stakeAddressInfo`), UTxO count.
    public func balance() async throws -> WalletBalance {
        let utxos = try await self.utxos()

        let rewardAddr = try await account.rewardAddress(with: keyManager)
        let rewards: UInt64?
        do {
            let info = try await chainContext.stakeAddressInfo(address: rewardAddr)
            // No entry: the stake address is not registered, so it holds none.
            rewards = try info.first.map { info in
                guard let balance = UInt64(exactly: info.rewardAccountBalance) else {
                    throw WalletError.providerError("Reward balance \(info.rewardAccountBalance) is negative")
                }
                return balance
            } ?? 0
        } catch let error as WalletError {
            throw error
        } catch {
            // The backend failed, or doesn't support the call: the rewards are unknown,
            // which is not the same as none.
            rewards = nil
        }

        return try WalletBalance.of(utxos, rewards: rewards)
    }

    // MARK: - Path resolution

    /// Reverse-lookup a payment path for an address the tracker has previously derived.
    ///
    /// Covers every address the last sweep derived (both roles, at least `gapLimit` each),
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
            for index in 0..<(scannedCount[role] ?? gapLimit) {
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
