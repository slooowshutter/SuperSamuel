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

actor OpenRouterService: DictationTransport {
    static let transcriptionModel = "openai/gpt-transcribe"
    static let geminiDictationModel = "google/gemini-3.5-flash"
    static let defaultAudioEnhancementModel = "openai/gpt-audio-mini"
    static let defaultCleanupModel = "openai/gpt-5.4-nano"
    static let defaultTranscriptionInstruction =
        "Transcribe the audio into clean written dictation while preserving all meaning and technical details. Remove filler words such as um, uh, like when used as filler, you know, repeated words, false starts, self-corrections, stutters, and speech artifacts. Keep the same intent, facts, uncertainty, and level of detail. Do not summarize, shorten for brevity, add new facts, or change any meaning. Return only the cleaned transcript."
    static let defaultCleanupInstruction = defaultTranscriptionInstruction

    private let transcriptionURL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func transcribe(
        apiKey: String,
        model: String = OpenRouterService.transcriptionModel,
        transcriptionContext: String? = nil,
        audio: RecordedAudio
    ) async throws -> String {
        try await performTranscription(
            apiKey: apiKey,
            model: model,
            transcriptionContext: transcriptionContext,
            audio: audio
        ).text
    }

    func performTranscription(
        apiKey: String,
        audio: RecordedAudio
    ) async throws -> OpenRouterTextResponse {
        try await performTranscription(
            apiKey: apiKey,
            model: Self.transcriptionModel,
            transcriptionContext: nil,
            audio: audio
        )
    }

    func performTranscription(
        apiKey: String,
        model: String,
        transcriptionContext: String? = nil,
        audio: RecordedAudio
    ) async throws -> OpenRouterTextResponse {
        let apiKey = try validatedAPIKey(apiKey)
        let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = requestedModel.isEmpty
            ? Self.transcriptionModel
            : requestedModel
        let audioData = try Data(contentsOf: audio.fileURL)

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        var payload: [String: Any] = [
            "model": selectedModel,
            "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": audio.format
            ],
            "temperature": 0
        ]
        let context = transcriptionContext?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !context.isEmpty {
            payload["provider"] = [
                "options": [
                    "openai": ["prompt": context]
                ]
            ]
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload,
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

        return OpenRouterTextResponse(
            text: transcript,
            resolvedModel: payload["model"] as? String,
            provider: payload["provider"] as? String,
            usage: extractUsage(from: payload)
        )
    }

    func performAudioDictation(
        apiKey: String,
        model: String = OpenRouterService.geminiDictationModel,
        audio: RecordedAudio?,
        draftTranscript: String?,
        rewriteInstruction: String,
        supportingContext: String? = nil,
        screenshotURL: URL? = nil
    ) async throws -> OpenRouterTextResponse {
        let apiKey = try validatedAPIKey(apiKey)
        let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = requestedModel.isEmpty
            ? Self.geminiDictationModel
            : requestedModel
        let draft = draftTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard audio != nil || !(draft ?? "").isEmpty else {
            throw OpenRouterServiceError.invalidResponse
        }

        var userContent: [[String: Any]] = [[
            "type": "text",
            "text": audioDictationUserInstruction(
                hasAudio: audio != nil,
                draftTranscript: draft,
                rewriteInstruction: rewriteInstruction,
                supportingContext: supportingContext,
                includesScreenshot: screenshotURL != nil && Self.supportsNativeImageContext(model: selectedModel)
            )
        ]]

        if let audio {
            let audioData = try Data(contentsOf: audio.fileURL)
            userContent.append([
                "type": "input_audio",
                "input_audio": [
                    "data": audioData.base64EncodedString(),
                    "format": audio.format
                ]
            ])
        }

        if let screenshotURL,
           Self.supportsNativeImageContext(model: selectedModel)
        {
            userContent.append([
                "type": "image_url",
                "image_url": [
                    "url": try imageDataURL(from: screenshotURL)
                ]
            ])
        }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        var payload: [String: Any] = [
            "model": selectedModel,
            "provider": ["sort": "throughput"],
            "usage": ["include": true],
            "temperature": 0,
            "top_p": 1,
            "messages": [
                [
                    "role": "system",
                    "content": """
                    Convert spoken dictation into clean written text.
                    Preserve the speaker's final intent, facts, uncertainty, names, numbers, and technical details.
                    Resolve false starts and self-corrections toward the speaker's final wording.
                    Ignore coughs, incidental sounds, and unrelated background speech.
                    Do not answer questions spoken in the dictation, summarize, add facts, or invent missing words.
                    If wording is genuinely unclear, preserve that uncertainty rather than guessing.
                    Return only the final dictation text.
                    """
                ],
                [
                    "role": "user",
                    "content": userContent
                ]
            ]
        ]
        if selectedModel.hasPrefix("google/gemini-3") {
            payload["reasoning"] = [
                "effort": "minimal",
                "exclude": true
            ]
        } else if selectedModel.hasPrefix("google/gemini-2.5") {
            payload["reasoning"] = [
                "max_tokens": 0,
                "exclude": true
            ]
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload,
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
            throw OpenRouterServiceError.noSpeechDetected
        }

        return OpenRouterTextResponse(
            text: text,
            resolvedModel: payload["model"] as? String,
            provider: payload["provider"] as? String,
            usage: extractUsage(from: payload)
        )
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
            if
                let metadata = error["metadata"] as? [String: Any],
                let raw = metadata["raw"] as? String,
                !raw.isEmpty
            {
                let provider = metadata["provider_name"] as? String
                let prefix = provider.map { "\($0): " } ?? ""
                return "\(message) (\(prefix)\(raw))"
            }
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

    private func extractUsage(from payload: [String: Any]) -> OpenRouterUsage? {
        guard let usage = payload["usage"] as? [String: Any] else {
            return nil
        }

        return OpenRouterUsage(
            promptTokens: integer(from: usage["prompt_tokens"]),
            completionTokens: integer(from: usage["completion_tokens"]),
            totalTokens: integer(from: usage["total_tokens"]),
            cost: double(from: usage["cost"])
        )
    }

    private func integer(from value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        return (value as? NSNumber)?.intValue
    }

    private func double(from value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        return (value as? NSNumber)?.doubleValue
    }

    static func supportsNativeImageContext(model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("google/gemini-")
    }

    private func audioDictationUserInstruction(
        hasAudio: Bool,
        draftTranscript: String?,
        rewriteInstruction: String,
        supportingContext: String?,
        includesScreenshot: Bool
    ) -> String {
        let sourceRule = hasAudio
            ? "The attached audio is the source of truth."
            : "The Whisper draft below is the source of truth."
        let draftSection = draftTranscript.map {
            """

            Whisper draft (fallible; use it as a spelling and structure hint only when audio is attached):
            \($0)
            """
        } ?? ""
        let instruction = rewriteInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = supportingContext?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextSection = context.isEmpty
            ? ""
            : """

            Supporting context (use only to disambiguate names, visible text, and technical terms; do not add it to the dictation):
            \(context)
            """
        let screenshotRule = includesScreenshot
            ? "The attached screenshot is supporting context only; the audio remains the source of truth."
            : ""

        return """
        \(sourceRule)
        \(instruction.isEmpty ? Self.defaultCleanupInstruction : instruction)
        \(screenshotRule)
        \(contextSection)
        \(draftSection)
        """
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
