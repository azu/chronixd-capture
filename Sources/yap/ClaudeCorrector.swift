import Foundation

/// Corrects transcription using `claude -p` CLI with multimodal input (screenshots).
final class ClaudeCorrector: Sendable {
    static let timeoutSeconds: Double = 30

    private static let systemPrompt = """
        You are a transcription corrector. Given a speech transcription segment, screen context \
        (application name, window title), and screenshots of the user's displays, correct any \
        misrecognized words. Focus on: technical terms, proper nouns, and words visible on screen. \
        Preserve the original meaning. Only fix recognition errors, do not rephrase. \
        Output ONLY the corrected text, nothing else.
        """

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
        var prompt = "Transcription: \(text)\n\nScreen context:\n"
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
            prompt += "\nScreenshots of the user's displays are attached."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = ["claude", "-p", "--output-format", "text"]
        for path in context.screenshotPaths {
            arguments += ["--file", path]
        }
        arguments.append(prompt)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
