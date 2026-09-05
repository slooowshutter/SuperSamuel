import Foundation
import Security
import CryptoKit

final class CredentialStore {
    private let service: String
    private let account: String
    private let localDirectory: URL

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.supersamuel.app",
        account: String = "openrouter-api-key",
        localDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperSamuel/Credentials", isDirectory: true)
    ) {
        self.service = service
        self.account = account
        self.localDirectory = localDirectory
    }

    func readAPIKey(useLocalStorage: Bool = false) -> String? {
        do {
            return try useLocalStorage ? readLocalAPIKey() : readKeychainAPIKey()
        } catch {
            return nil
        }
    }

    func readKeychainAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw CredentialStoreError.keychain(errSecDecode) }
        guard let key = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(errSecDecode)
        }
        return key
    }

    func readLocalAPIKey() throws -> String? {
        do {
            let data = try Data(contentsOf: localFile)
            guard let key = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.keychain(errSecDecode)
            }
            return key.isEmpty ? nil : key
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private var localFile: URL {
        let identity = Data((service + "\u{0}" + account).utf8)
        let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return localDirectory.appendingPathComponent(name + ".key")
    }

    func writeAPIKey(_ apiKey: String, useLocalStorage: Bool = false) throws {
        if useLocalStorage {
            let manager = FileManager.default
            try manager.createDirectory(at: localDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localDirectory.path)
            // The replacement is private from creation, including its temporary file.
            let temporary = localDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: Data(apiKey.utf8))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, localFile.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if apiKey.isEmpty {
            let status = SecItemDelete(lookup as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
            return
        }

        let data = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = lookup
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }
}

private enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        }
    }
}
