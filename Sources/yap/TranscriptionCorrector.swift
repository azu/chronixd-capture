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

    private let session: LanguageModelSession

    init() {
        self.session = LanguageModelSession(
            instructions: """
            You are a transcription corrector. Given a speech transcription segment and the screen context \
            (application name, window title, visible text), correct any misrecognized words.
            Focus on: technical terms, proper nouns, and words that should match the on-screen context.
            Preserve the original meaning. Only fix recognition errors, do not rephrase.
            """
        )
    }

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
            if display.isPlayingMedia {
                prompt += "⚠️ This display is playing media/video. Audio from the video may be mixed in. Focus on correcting the user's own speech, not video dialogue.\n"
            }
            if !display.ocrText.isEmpty {
                prompt += "Screen text:\n\(display.ocrText)\n"
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
