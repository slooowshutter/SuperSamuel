import Foundation
import XCTest
@testable import SuperSamuelApp

@MainActor
final class SettingsStoreTests: XCTestCase {
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
