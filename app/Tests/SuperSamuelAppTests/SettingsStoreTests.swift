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
}
