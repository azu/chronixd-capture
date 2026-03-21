// Sources/yap/TranscriptionCorrector.swift
import FoundationModels

@Generable
struct CorrectionResult {
    @Guide(description: "Corrected transcription text based on screen context. If no correction is needed, return the original text unchanged.")
    let corrected: String
}

actor TranscriptionCorrector {
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

    /// Correct a transcription segment using screen context.
    /// Returns (original, corrected) tuple. On timeout or error, corrected == original.
    func correct(text: String, context: ScreenContext) async -> (original: String, corrected: String) {
        do {
            let corrected = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await self.performCorrection(text: text, context: context)
            }
            return (original: text, corrected: corrected)
        } catch {
            return (original: text, corrected: text)
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
            generating: CorrectionResult.self
        )
        return result.content.corrected
    }

    /// Execute an async closure with a timeout. Cancels the operation on timeout.
    private func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await operation() }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            task.cancel()
        }
        do {
            let result = try await task.value
            timeoutTask.cancel()
            return result
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }
}
