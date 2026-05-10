import Foundation

/// JSON-on-disk ``KeyStore``. One file per id, named `<id>.json`, in a single directory.
public actor FileKeyStore: KeyStore {

    public let directory: URL

    /// Creates the directory if it doesn't already exist.
    public init(directory: URL, createIfMissing: Bool = true) throws {
        self.directory = directory
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
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
