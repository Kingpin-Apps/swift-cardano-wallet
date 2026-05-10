import Foundation

/// Storage backend for ``EncryptedBlob``s, addressed by an opaque string id.
///
/// Default implementations:
/// - ``FileKeyStore`` — JSON-on-disk, per-id files in a single directory.
/// - `KeychainKeyStore` (PR 14, Apple platforms only).
public protocol KeyStore: Sendable {
    func save(_ blob: EncryptedBlob, id: String) async throws
    func load(id: String) async throws -> EncryptedBlob
    func delete(id: String) async throws
    func list() async throws -> [String]
}
