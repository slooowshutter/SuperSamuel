import Foundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testCleanupIsOptionalAndPersistsFullInstructions() throws {
        let suite = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suite))
        XCTAssertNil(settings.cleanupConfiguration)
        XCTAssertEqual(settings.cleanupInstructions, OpenRouterService.defaultCleanupInstruction)
        settings.cleanupEnabled = true
        settings.cleanupInstructions = String(repeating: "Keep names. ", count: 200)
        settings.cleanupModel = "  google/gemini-3.8-flash  "
        let reloaded = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suite))
        XCTAssertEqual(reloaded.cleanupConfiguration, settings.cleanupConfiguration)
        XCTAssertEqual(reloaded.cleanupModel, "google/gemini-3.8-flash")
        reloaded.cleanupEnabled = false
        XCTAssertNil(reloaded.cleanupConfiguration)
        XCTAssertEqual(reloaded.cleanupInstructions, settings.cleanupInstructions)
    }

    func testTranscriptionModelCanBeChangedAndPersists() {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suiteName))
        XCTAssertEqual(settings.transcriptionModel, "openai/gpt-transcribe")
        settings.transcriptionModel = "custom/transcription-model"
        let reloaded = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suiteName))
        XCTAssertEqual(reloaded.transcriptionModel, "custom/transcription-model")
    }

    func testOldPromptsAreReplacedOnceAndSubsequentEditsSurviveRelaunch() {
        let suite = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["openRouterCleanupPrompt", "openRouterTranscriptionContext", "transcriptCleanupInstructions"] {
            defaults.set("Old instructions that must no longer apply.", forKey: key)
        }
        defaults.set(true, forKey: "transcriptCleanupEnabled")
        defaults.set("custom/cleanup-model", forKey: "transcriptCleanupModel")
        defaults.set(["SuperSamuel"], forKey: "personalDictionary")

        let settings = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suite))
        XCTAssertEqual(settings.cleanupInstructions, OpenRouterService.defaultCleanupInstruction)
        XCTAssertNil(defaults.object(forKey: "openRouterCleanupPrompt"))
        XCTAssertNil(defaults.object(forKey: "openRouterTranscriptionContext"))
        XCTAssertNil(defaults.object(forKey: "transcriptCleanupInstructions"))
        XCTAssertTrue(settings.cleanupEnabled)
        XCTAssertEqual(settings.cleanupModel, "custom/cleanup-model")
        XCTAssertEqual(settings.personalDictionary, ["SuperSamuel"])

        settings.cleanupInstructions = "My new editing instructions."
        let reloaded = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suite))
        XCTAssertEqual(reloaded.cleanupConfiguration?.instructions, "My new editing instructions.")
    }

    func testBlankCleanupInstructionsUseTheSameDefault() {
        let suite = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suite))
        settings.cleanupEnabled = true
        settings.cleanupInstructions = "  \n "
        let reloaded = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suite))
        XCTAssertEqual(reloaded.cleanupConfiguration?.instructions, OpenRouterService.defaultCleanupInstruction)
    }

    func testRealtimeOpenAIKeyUsesSeparateKeychainEntry() throws {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let openRouterCredentials = CredentialStore(service: suiteName)
        let openAICredentials = CredentialStore(
            service: suiteName,
            account: "openai-api-key"
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? openRouterCredentials.writeAPIKey("")
            try? openAICredentials.writeAPIKey("")
        }

        let settings = SettingsStore(
            defaults: defaults,
            credentials: openRouterCredentials,
            openAICredentials: openAICredentials
        )
        settings.openRouterAPIKey = "sk-or-test"

        XCTAssertEqual(settings.openRouterAPIKey, "sk-or-test")
        XCTAssertEqual(
            settings.realtimeTranscriptionAvailability,
            .missingOpenAIAPIKey
        )
        XCTAssertFalse(settings.canUseRealtimeGPTTranscribe)

        settings.openAIAPIKey = "sk-openai-test"

        XCTAssertEqual(settings.openAIAPIKey, "sk-openai-test")
        XCTAssertTrue(settings.realtimeTranscriptionEnabled)
        XCTAssertEqual(settings.realtimeTranscriptionAvailability, .available)
        XCTAssertTrue(settings.canUseRealtimeGPTTranscribe)

        settings.transcriptionModel = "mistralai/voxtral-mini-transcribe"
        XCTAssertEqual(
            settings.realtimeTranscriptionAvailability,
            .available
        )
        XCTAssertTrue(settings.canUseRealtimeGPTTranscribe)
    }

    func testDelayDefaultsAndEveryPresetPersists() {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suiteName))
        XCTAssertEqual(settings.transcriptionDelay, .xhigh)
        for delay in TranscriptionDelay.allCases {
            settings.transcriptionDelay = delay
            let reloaded = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suiteName))
            XCTAssertEqual(reloaded.transcriptionDelay, delay)
        }
        defaults.set("unsupported", forKey: "realtimeTranscriptionDelay")
        XCTAssertEqual(settings.transcriptionDelay, .xhigh)
    }

    func testDictionaryNormalizesAndRejectsInvalidEditsWithoutLosingSavedTerms() throws {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suiteName))
        try settings.setPersonalDictionary(["  SuperSamuel  ", "", "supersamuel", "Café", "Cafe\u{301}", "GPT Live Transcribe"])
        XCTAssertEqual(settings.personalDictionary, ["SuperSamuel", "Café", "GPT Live Transcribe"])
        for invalid in ["<tag>", "a>b", "a\nb", "a\rb", "a\tb", "a\u{0}b", "a\u{2028}b"] {
            XCTAssertThrowsError(try settings.setPersonalDictionary(["New term", invalid]))
            XCTAssertEqual(settings.personalDictionary, ["SuperSamuel", "Café", "GPT Live Transcribe"])
        }
        let reloaded = SettingsStore(defaults: defaults, credentials: CredentialStore(service: suiteName))
        XCTAssertEqual(reloaded.personalDictionary, settings.personalDictionary)
    }

}
