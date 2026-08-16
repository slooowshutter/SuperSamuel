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

        let reloadedSettings = SettingsStore(
            defaults: defaults,
            credentials: CredentialStore(service: suiteName)
        )
        XCTAssertEqual(
            reloadedSettings.transcriptionModel,
            "custom/transcription-model"
        )
    }

    func testAudioEnhancementDefaultsToGPTAudioMini() {
        let suiteName = "SuperSamuelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(
            defaults: defaults,
            credentials: CredentialStore(service: suiteName)
        )

        XCTAssertEqual(
            settings.enhancementModel,
            OpenRouterService.defaultAudioEnhancementModel
        )
        XCTAssertTrue(settings.enhancementEnabledByDefault)
    }
}
