import Foundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class CredentialStoreTests: XCTestCase {
    func testLocalKeysSurviveRelaunchAndClearingDoesNotRestoreKeychainBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let router = CredentialStore(service: suite, localDirectory: directory)
        let openAI = CredentialStore(service: suite, account: "openai", localDirectory: directory)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? router.writeAPIKey("")
            try? openAI.writeAPIKey("")
            try? FileManager.default.removeItem(at: directory)
        }
        try router.writeAPIKey("router-example")
        try openAI.writeAPIKey("openai-example")
        let settings = SettingsStore(defaults: defaults, credentials: router, openAICredentials: openAI)
        XCTAssertFalse(settings.usesLocalCredentials)
        try settings.useLocalCredentialStorage()
        XCTAssertTrue(settings.usesLocalCredentials)
        XCTAssertEqual(try router.readKeychainAPIKey(), "router-example")
        XCTAssertEqual(try openAI.readKeychainAPIKey(), "openai-example")

        let reloaded = SettingsStore(defaults: defaults,
            credentials: CredentialStore(service: suite, localDirectory: directory),
            openAICredentials: CredentialStore(service: suite, account: "openai", localDirectory: directory))
        XCTAssertTrue(reloaded.usesLocalCredentials)
        XCTAssertEqual(reloaded.openRouterAPIKey, "router-example")
        XCTAssertEqual(reloaded.openAIAPIKey, "openai-example")
        reloaded.openRouterAPIKey = "updated-example"
        XCTAssertEqual(try router.readLocalAPIKey(), "updated-example")
        reloaded.openRouterAPIKey = ""
        XCTAssertEqual(reloaded.openRouterAPIKey, "")
        XCTAssertEqual(try router.readKeychainAPIKey(), "router-example")
        try reloaded.useLocalCredentialStorage()
        XCTAssertEqual(reloaded.openRouterAPIKey, "")

        let manager = FileManager.default
        let permissions = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testFailedMigrationKeepsKeychainSelectedAndPreservesKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let router = CredentialStore(service: suite, localDirectory: directory)
        let openAI = CredentialStore(service: suite, account: "openai", localDirectory: directory)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? router.writeAPIKey("")
            try? openAI.writeAPIKey("")
            try? FileManager.default.removeItem(at: directory)
        }
        try router.writeAPIKey("saved-example")
        // A file where the credentials directory should be makes migration fail.
        try Data().write(to: directory)
        let settings = SettingsStore(defaults: defaults, credentials: router, openAICredentials: openAI)
        XCTAssertThrowsError(try settings.useLocalCredentialStorage())
        XCTAssertFalse(settings.usesLocalCredentials)
        XCTAssertEqual(settings.openRouterAPIKey, "saved-example")
    }

    func testLocalFilesSeparateAccountsAndServices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CredentialStore(service: "one", account: "key", localDirectory: directory)
        let second = CredentialStore(service: "two", account: "key", localDirectory: directory)
        XCTAssertNil(try first.readLocalAPIKey())
        try first.writeAPIKey("first-example", useLocalStorage: true)
        try second.writeAPIKey("second-example", useLocalStorage: true)
        XCTAssertEqual(try first.readLocalAPIKey(), "first-example")
        XCTAssertEqual(try second.readLocalAPIKey(), "second-example")
    }
}
