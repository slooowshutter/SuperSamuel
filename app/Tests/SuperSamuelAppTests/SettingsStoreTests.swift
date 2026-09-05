import Foundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testTranscriptionModelCanBeChangedAndPersists() {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(
            defaults: defaults,
            credentials: CredentialStore(service: suiteName)
        )

        settings.transcriptionModel = "custom/transcription-model"
        settings.transcriptionContext =
            "Expected terms include SuperSamuel and OpenRouter."

        let reloadedSettings = SettingsStore(
            defaults: defaults,
            credentials: CredentialStore(service: suiteName)
        )
        XCTAssertEqual(
            reloadedSettings.transcriptionModel,
            "custom/transcription-model"
        )
        XCTAssertEqual(
            reloadedSettings.transcriptionContext,
            "Expected terms include SuperSamuel and OpenRouter."
        )
    }

    func testTranscriptionDefaultsToGPTTranscribeWithInstructions() {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(
            defaults: defaults,
            credentials: CredentialStore(service: suiteName)
        )

        XCTAssertEqual(
            settings.transcriptionModel,
            "openai/gpt-transcribe"
        )
        XCTAssertEqual(
            settings.transcriptionContext,
            OpenRouterService.defaultTranscriptionInstruction
        )
    }

    func testLegacyCleanupPromptBecomesTranscriptionInstructions() {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "Preserve Gemini 3.6 exactly.",
            forKey: "openRouterCleanupPrompt"
        )

        let settings = SettingsStore(
            defaults: defaults,
            credentials: CredentialStore(service: suiteName)
        )

        XCTAssertEqual(
            settings.transcriptionContext,
            "Preserve Gemini 3.6 exactly."
        )
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
