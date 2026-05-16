import Foundation

/// JSON-on-disk ``KeyStore``. One file per id, named `<id>.json`, in a single directory.
public actor FileKeyStore: KeyStore {

    public let directory: URL

    /// Creates the directory if it doesn't already exist. Newly-created directories are
    /// chmod'd to `0o700` (owner read/write/execute, group/other none) so the encrypted
    /// blobs inside aren't world-readable on a multi-user machine. Existing directories
    /// are left untouched — the caller already chose their own permissions for those.
    public init(directory: URL, createIfMissing: Bool = true) throws {
        self.directory = directory
        if createIfMissing {
            let alreadyExisted = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if !alreadyExisted {
                #if !os(Windows)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
                #endif
            }
        } else {
            var isDir: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
                isDir.boolValue
            else {
                throw WalletError.keystore("Directory does not exist: \(directory.path)")
            }
        }
    }

    public func save(_ blob: EncryptedBlob, id: String) async throws {
        try Self.validate(id: id)
        let url = fileURL(for: id)
        do {
            let data = try blob.toJSONData()
            try data.write(to: url, options: [.atomic])
        } catch {
            throw WalletError.keystore("Cannot write \(url.path): \(error)")
        }
        // Set 0o600 every time, not only on first write — atomic writes rename a temp
        // file over the target, so the resulting inode may have just-created
        // (umask-dependent) permissions even when the previous file was already 0o600.
        #if !os(Windows)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #endif
    }

    public func load(id: String) async throws -> EncryptedBlob {
        try Self.validate(id: id)
        let url = fileURL(for: id)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WalletError.keystore("Cannot read \(url.path): \(error)")
        }
        return try EncryptedBlob.fromJSONData(data)
    }

    public func delete(id: String) async throws {
        try Self.validate(id: id)
        let url = fileURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return  // idempotent
        } catch {
            throw WalletError.keystore("Cannot delete \(url.path): \(error)")
        }
    }

    public func list() async throws -> [String] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WalletError.keystore("Cannot enumerate \(directory.path): \(error)")
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: - Internals

    private nonisolated func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Reject ids that could escape the directory (`..`, `/`, etc.). Allow alphanumerics + dash + underscore.
    private static func validate(id: String) throws {
        guard !id.isEmpty else {
            throw WalletError.keystore("KeyStore id cannot be empty")
        }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw WalletError.keystore("KeyStore id contains illegal characters: \(id)")
        }
        guard !id.contains("..") else {
            throw WalletError.keystore("KeyStore id cannot contain '..'")
        }
    }
}
