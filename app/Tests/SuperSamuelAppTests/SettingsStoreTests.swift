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
            .unsupportedModel
        )
        XCTAssertFalse(settings.canUseRealtimeGPTTranscribe)
    }
}
