import Foundation

enum OpenRouterServiceError: LocalizedError {
    case missingAPIKey
    case noSpeechDetected
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Settings before recording."
        case .noSpeechDetected:
            return "No speech was detected. The recording was kept so you can retry it or move it to Trash."
        case .requestFailed(let message):
            return "OpenRouter request failed: \(message)"
        case .invalidResponse:
            return "OpenRouter returned an invalid response."
        }
    }
}

actor OpenRouterService {
    static let transcriptionModel = "openai/whisper-large-v3"
    static let defaultCleanupModel = "openai/gpt-5.4-nano"
    static let defaultCleanupInstruction =
        "Rewrite the raw transcript into clean written dictation while preserving all meaning and technical details. Remove filler words such as um, uh, like when used as filler, you know, repeated words, false starts, self-corrections, stutters, and speech artifacts. Keep the same intent, facts, uncertainty, and level of detail. Do not summarize, shorten for brevity, add new facts, or change any meaning. Return only the cleaned transcript."

    private let transcriptionURL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func transcribe(apiKey: String, audio: RecordedAudio) async throws -> String {
        let apiKey = try validatedAPIKey(apiKey)
        let audioData = try Data(contentsOf: audio.fileURL)

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": Self.transcriptionModel,
                "input_audio": [
                    "data": audioData.base64EncodedString(),
                    "format": audio.format
                ],
                "temperature": 0
            ],
            options: []
        )

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)

        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = payload["text"] as? String
        else {
            throw OpenRouterServiceError.invalidResponse
        }

        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw OpenRouterServiceError.noSpeechDetected
        }

        return transcript
    }

    func cleanupTranscript(
        apiKey: String,
        model: String,
        rewriteInstruction: String,
        rawTranscript: String,
        screenshotURL: URL? = nil
    ) async throws -> String {
        let apiKey = try validatedAPIKey(apiKey)
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw OpenRouterServiceError.invalidResponse
        }

        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": selectedModel.isEmpty ? Self.defaultCleanupModel : selectedModel,
                "messages": [
                    [
                        "role": "system",
                        "content": """
                        You convert messy spoken dictation into clean written text.
                        Treat the raw transcript as the source of truth and rewrite it into natural, readable dictation.
                        Preserve all concrete meaning, technical details, intent, uncertainty, and important qualifiers.
                        If a screenshot is attached, use it only to disambiguate visible app names, labels, UI text, filenames, or technical terms.
                        Never let the screenshot override the transcript.
                        Do not summarize, answer the transcript, add new facts, or change the meaning.
                        Return only the cleaned transcript.
                        """
                    ],
                    [
                        "role": "user",
                        "content": try buildUserMessageContent(
                            transcript: transcript,
                            rewriteInstruction: rewriteInstruction,
                            screenshotURL: screenshotURL
                        )
                    ]
                ]
            ],
            options: []
        )

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)

        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = payload["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"]
        else {
            throw OpenRouterServiceError.invalidResponse
        }

        let text = extractText(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenRouterServiceError.invalidResponse
        }

        return text
    }

    private func validatedAPIKey(_ apiKey: String) throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenRouterServiceError.missingAPIKey
        }
        return trimmed
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let status = "HTTP \(httpResponse.statusCode)"
            let message = extractErrorMessage(from: data).map {
                "\(status): \($0)"
            } ?? status
            throw OpenRouterServiceError.requestFailed(message)
        }
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if
            let error = payload["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        {
            return message
        }

        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }

        return nil
    }

    private func extractText(from content: Any) -> String {
        if let text = content as? String {
            return text
        }

        guard let parts = content as? [[String: Any]] else {
            return ""
        }

        return parts
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private func buildUserMessageContent(
        transcript: String,
        rewriteInstruction: String,
        screenshotURL: URL?
    ) throws -> Any {
        let textContent = """
        Raw transcript to rewrite:
        \(transcript)

        Rewrite rules:
        \(rewriteInstruction)
        """

        guard let screenshotURL else {
            return textContent
        }

        return [
            [
                "type": "text",
                "text": """
                \(textContent)

                Use the attached screenshot only as supporting context. If it conflicts with the transcript, trust the transcript.
                """
            ],
            [
                "type": "image_url",
                "image_url": [
                    "url": try imageDataURL(from: screenshotURL)
                ]
            ]
        ]
    }

    private func imageDataURL(from fileURL: URL) throws -> String {
        do {
            let data = try Data(contentsOf: fileURL)
            return "data:image/jpeg;base64,\(data.base64EncodedString())"
        } catch {
            throw OpenRouterServiceError.requestFailed("The attached screenshot could not be read.")
        }
    }
}
