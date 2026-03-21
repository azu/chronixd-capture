// Sources/yap/TranscriptionCorrector.swift
import FoundationModels

@Generable
struct LLMCorrectionOutput {
    @Guide(description: "Corrected transcription text based on screen context. If no correction is needed, return the original text unchanged.")
    let corrected: String
}

actor TranscriptionCorrector: Corrector {
    /// Timeout for correction in seconds. If exceeded, original text is returned.
    static let timeoutSeconds: UInt64 = 5
    /// Max OCR chars per display for the ~3B on-device model.
    static let maxOCRCharsPerDisplay = 500

    private static let instructions = """
        You are a speech-to-text corrector. The input is raw voice transcription that may contain:
        - Misrecognized technical terms and proper nouns (use screen context to fix)
        - Missing or incorrect punctuation
        - Filler words (えーと, あの, まあ, うーん, etc.)
        - Repetitions and false starts

        Rules:
        - Fix misrecognized words using screen context (app name, window title, visible text)
        - Add appropriate punctuation (。、！？) for natural Japanese text
        - Remove filler words and meaningless repetitions
        - Keep the speaker's intended meaning intact
        - Output the corrected text only, no explanations
        """

    init() {}

    func correct(text: String, context: ScreenContext) async -> CorrectionResult {
        do {
            let corrected = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await self.performCorrection(text: text, context: context)
            }
            let status: CorrectionStatus = corrected == text ? .unchanged : .corrected
            return CorrectionResult(original: text, corrected: corrected, status: status)
        } catch is CancellationError {
            return CorrectionResult(original: text, corrected: text, status: .timeout)
        } catch {
            return CorrectionResult(original: text, corrected: text, status: .error(error.localizedDescription))
        }
    }

    private func performCorrection(text: String, context: ScreenContext) async throws -> String {
        // Create a fresh session per correction to avoid context window overflow
        let session = LanguageModelSession(instructions: Self.instructions)

        var prompt = "Transcription: \(text)\n\nScreen context:\n"
        for display in context.displays {
            prompt += display.isFocused ? "### Focused Display\n" : "### Display\n"
            if let appName = display.appName {
                prompt += "Application: \(appName)\n"
            }
            if let windowTitle = display.windowTitle {
                prompt += "Window: \(windowTitle)\n"
            }
            if let url = display.url {
                prompt += "URL: \(url)\n"
            }
            if !display.ocrText.isEmpty {
                // Limit OCR for the small on-device model
                let truncated = String(display.ocrText.prefix(Self.maxOCRCharsPerDisplay))
                prompt += "Screen text:\n\(truncated)\n"
            }
            prompt += "\n"
        }

        let result = try await session.respond(
            to: prompt,
            generating: LLMCorrectionOutput.self
        )
        return result.content.corrected
    }

    /// Execute an async closure with a timeout. Returns nil on timeout.
    private func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            // First to complete wins
            while let result = try await group.next() {
                if let value = result {
                    group.cancelAll()
                    return value
                }
                // Timeout task returned nil
                group.cancelAll()
                throw CancellationError()
            }
            throw CancellationError()
        }
    }
}
