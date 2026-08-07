import Foundation
import Vision

enum ScreenshotContextExtractor {
    private static let maximumCharacters = 12_000

    static func extractText(from fileURL: URL?) async -> String? {
        guard let fileURL else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(url: fileURL).perform([request])
            } catch {
                return nil
            }

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            return String(text.prefix(maximumCharacters))
        }.value
    }
}
