#if WALLET_HAS_SQLITE

import Foundation
import SwiftCardanoCore
import SQLite

/// Durable ``UTxOStore`` backed by `SQLite.swift`. Available only when this package is built
/// with the `SQLite` trait enabled (see `Package.swift`).
///
/// Stores each UTxO as a CBOR blob keyed by `(address, tx_id, output_index)`. On open the
/// schema is created or migrated to the current version. Address values are stored as their
/// bech32 representation; lookups round-trip through ``SwiftCardanoCore/Address``.
///
/// Construction is async because opening the database may run a migration; use the static
/// ``open(filePath:)`` factory or ``open(inMemory:)`` for tests. The actor owns the
/// `Connection` — all access is naturally serialized.
public actor SQLiteUTxOStore: UTxOStore {

    /// Bumped on every breaking schema change. Mismatches at open time trigger a destructive
    /// reset for now (PR 10 has only one schema version). Future PRs can do real migrations.
    public static let schemaVersion: Int32 = 1

    private let connection: Connection

    private init(connection: Connection) throws {
        self.connection = connection
        try Self.bootstrapSchema(connection: connection)
    }

    // MARK: - Factories

    /// Open or create a SQLite-backed store at `filePath`. Parent directory must already exist.
    public static func open(filePath: String) async throws -> SQLiteUTxOStore {
        do {
            let db = try Connection(.uri(filePath))
            try Self.applyPragmas(connection: db)
            return try SQLiteUTxOStore(connection: db)
        } catch let error as WalletError {
            throw error
        } catch {
            throw WalletError.keystore("Cannot open SQLite store at \(filePath): \(error)")
        }
    }

    /// In-memory store. Useful for tests; the database vanishes when the actor is deallocated.
    public static func openInMemory() async throws -> SQLiteUTxOStore {
        do {
            let db = try Connection(.inMemory)
            try Self.applyPragmas(connection: db)
            return try SQLiteUTxOStore(connection: db)
        } catch let error as WalletError {
            throw error
        } catch {
            throw WalletError.keystore("Cannot open in-memory SQLite store: \(error)")
        }
    }

    // MARK: - UTxOStore

    public func upsert(_ utxos: [UTxO], for address: Address) async throws {
        let bech32: String
        do {
            bech32 = try address.toBech32()
        } catch {
            throw WalletError.keystore("Cannot bech32-encode address for storage: \(error)")
        }
        do {
            try connection.transaction {
                try connection.run(
                    "DELETE FROM utxos WHERE address = ?",
                    bech32
                )
                let insert = try connection.prepare(
                    "INSERT INTO utxos (address, tx_id, output_index, cbor) VALUES (?, ?, ?, ?)"
                )
                for utxo in utxos {
                    let txId = utxo.input.transactionId.payload.toHex
                    let index = Int64(utxo.input.index)
                    let cbor = try utxo.toCBORData()
                    try insert.run(bech32, txId, index, Blob(bytes: [UInt8](cbor)))
                }
            }
        } catch {
            throw WalletError.keystore("upsert failed for \(bech32): \(error)")
        }
    }

    public func utxos(for address: Address) async throws -> [UTxO] {
        let bech32: String
        do {
            bech32 = try address.toBech32()
        } catch {
            throw WalletError.keystore("Cannot bech32-encode address for lookup: \(error)")
        }
        do {
            let stmt = try connection.prepare(
                "SELECT cbor FROM utxos WHERE address = ? ORDER BY output_index ASC",
                bech32
            )
            var out: [UTxO] = []
            for row in stmt {
                guard let blob = row[0] as? Blob else { continue }
                let cbor = Data(blob.bytes)
                let utxo = try UTxO.fromCBOR(data: cbor)
                out.append(utxo)
            }
            return out
        } catch {
            throw WalletError.keystore("read failed for \(bech32): \(error)")
        }
    }

    public func allAddresses() async throws -> [Address] {
        do {
            let stmt = try connection.prepare(
                "SELECT DISTINCT address FROM utxos ORDER BY address ASC"
            )
            var out: [Address] = []
            for row in stmt {
                guard let bech32 = row[0] as? String else { continue }
                let address = try Address(from: .string(bech32))
                out.append(address)
            }
            return out
        } catch {
            throw WalletError.keystore("listing addresses failed: \(error)")
        }
    }

    public func clear() async throws {
        do {
            try connection.run("DELETE FROM utxos")
        } catch {
            throw WalletError.keystore("clear failed: \(error)")
        }
    }

    // MARK: - Internals

    private static func applyPragmas(connection: Connection) throws {
        // WAL journaling: durable & better concurrent reads.
        try connection.execute("PRAGMA journal_mode = WAL;")
        // Foreign keys aren't strictly needed yet but are a sensible default.
        try connection.execute("PRAGMA foreign_keys = ON;")
    }

    private static func bootstrapSchema(connection: Connection) throws {
        let currentVersion: Int32 = (connection.userVersion ?? 0)
        if currentVersion != Self.schemaVersion {
            // For PR 10 we destructively reset on mismatch. Future PRs can migrate in place.
            try connection.execute("DROP TABLE IF EXISTS utxos;")
        }
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS utxos (
                address      TEXT    NOT NULL,
                tx_id        TEXT    NOT NULL,
                output_index INTEGER NOT NULL,
                cbor         BLOB    NOT NULL,
                PRIMARY KEY (address, tx_id, output_index)
            );
            """
        )
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_utxos_address ON utxos(address);"
        )
        connection.userVersion = Self.schemaVersion
    }
}

#endif
