import Foundation

/// Corrects transcription using `claude -p` CLI with multimodal input (screenshots).
final class ClaudeCorrector: Sendable {
    /// Timeout in seconds for each claude invocation.
    static let timeoutSeconds: Double = 30

    func correct(text: String, context: ScreenContext) async -> (original: String, corrected: String) {
        do {
            let corrected = try await runClaude(text: text, context: context)
            let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return (original: text, corrected: text)
            }
            return (original: text, corrected: trimmed)
        } catch {
            return (original: text, corrected: text)
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
        if let appName = context.appName {
            prompt += "Application: \(appName)\n"
        }
        if let windowTitle = context.windowTitle {
            prompt += "Window: \(windowTitle)\n"
        }
        if let focusedElement = context.focusedElement {
            prompt += "Focused element: \(focusedElement)\n"
        }
        if !context.screenshotPaths.isEmpty {
            prompt += "\nScreenshots of the user's displays (read these files to see what's on screen):\n"
            for path in context.screenshotPaths {
                prompt += "- \(path)\n"
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "claude", "-p",
            "--output-format", "text",
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

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            // Timeout: kill process if it takes too long
            let timeoutWork = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Self.timeoutSeconds,
                execute: timeoutWork
            )

            process.terminationHandler = { _ in
                timeoutWork.cancel()
                guard !resumed else { return }
                resumed = true
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}
