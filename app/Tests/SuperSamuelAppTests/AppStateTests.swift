import XCTest
@testable import SuperSamuelApp

@MainActor
final class AppStateTests: XCTestCase {
    func testTranscriptKeepsFullTextAndFivePreviewLines() {
        let state = AppState()
        let transcript = "one\ntwo\nthree\nfour\nfive\nsix\nseven"

        state.setTranscriptPreview(fullText: transcript)

        XCTAssertEqual(state.transcriptText, transcript)
        XCTAssertEqual(
            state.transcriptPreviewLines,
            ["three", "four", "five", "six", "seven"]
        )
    }

    func testProgressMessageReplacesScrollableTranscript() {
        let state = AppState()
        state.setTranscriptPreview(fullText: "A completed live transcript.")

        state.setProgressMessage("Finishing live transcript...")

        XCTAssertEqual(state.transcriptText, "Finishing live transcript...")
        XCTAssertEqual(
            state.transcriptPreviewLines,
            ["Finishing live transcript..."]
        )
    }
}
