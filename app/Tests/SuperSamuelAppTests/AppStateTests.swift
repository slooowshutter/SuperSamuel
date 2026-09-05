import XCTest
@testable import SuperSamuelApp

@MainActor
final class AppStateTests: XCTestCase {
    func testTranscriptKeepsFullText() {
        let state = AppState()
        let transcript = "one\ntwo\nthree\nfour\nfive\nsix\nseven"

        state.setTranscriptPreview(fullText: transcript)

        XCTAssertEqual(state.transcriptText, transcript)
    }

    func testProgressMessageReplacesScrollableTranscript() {
        let state = AppState()
        state.setTranscriptPreview(fullText: "A completed live transcript.")

        state.setProgressMessage("Finishing live transcript...")

        XCTAssertEqual(state.transcriptText, "Finishing live transcript...")
    }
}
