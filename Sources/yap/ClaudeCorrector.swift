import Foundation

/// Corrects transcription using `claude -p` CLI with multimodal input (screenshots).
final class ClaudeCorrector: Corrector, Sendable {
    /// Timeout in seconds for each claude invocation.
    static let timeoutSeconds: UInt64 = 30

    let model: String

    init(model: String = "haiku") {
        self.model = model
    }

    func correct(text: String, context: ScreenContext) async -> CorrectionResult {
        do {
            let corrected = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await self.runClaude(text: text, context: context)
            }
            let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return CorrectionResult(original: text, corrected: text, status: .error("empty response"))
            }
            let status: CorrectionStatus = trimmed == text ? .unchanged : .corrected
            return CorrectionResult(original: text, corrected: trimmed, status: status)
        } catch is CancellationError {
            return CorrectionResult(original: text, corrected: text, status: .timeout)
        } catch {
            return CorrectionResult(original: text, corrected: text, status: .error(error.localizedDescription))
        }
    }

    private func runClaude(text: String, context: ScreenContext) async throws -> String {
        var prompt = """
            You are a transcription corrector.

            ## Rules
            - If the transcription looks correct and nothing on screen contradicts it, output the original text EXACTLY as-is. Do not add punctuation, capitalization, or formatting.
            - Only fix words that are clearly misrecognized based on what is visible on screen.
            - Focus on: technical terms, proper nouns, variable/function names, and domain-specific words visible on screen.
            - Preserve the original meaning and style. Do not rephrase.
            - Output ONLY the corrected (or unchanged) text. No explanations, no quotes, no prefixes.

            ## Transcription
            \(text)

            ## Screen Context

            """
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
            if let path = display.screenshotPath {
                prompt += "Screenshot (read this file): \(path)\n"
            }
            prompt += "\n"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "claude", "-p",
            "--output-format", "text",
            "--model", model,
            "--no-session-persistence",
            "--disable-slash-commands",
            "--dangerously-skip-permissions",
            "--setting-sources", "",
            prompt,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }

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
