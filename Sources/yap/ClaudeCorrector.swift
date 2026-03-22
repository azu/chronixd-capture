import Foundation

/// Corrects transcription using `claude -p` CLI with multimodal input (screenshots).
final class ClaudeCorrector: Corrector, @unchecked Sendable {
    /// Timeout in seconds for each claude invocation.
    static let timeoutSeconds: UInt64 = 30
    /// How far back to include previous segments as context.
    static let contextWindowSeconds: TimeInterval = 600 // 10 minutes

    let model: String
    private var history: [(text: String, timestamp: Date)] = []
    private let lock = NSLock()

    init(model: String = "haiku") {
        self.model = model
    }

    private func addToHistory(_ text: String) {
        let now = Date()
        lock.lock()
        history.append((text: text, timestamp: now))
        // Remove entries older than context window
        let cutoff = now.addingTimeInterval(-Self.contextWindowSeconds)
        history.removeAll { $0.timestamp < cutoff }
        lock.unlock()
    }

    private func getRecentHistory() -> [String] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.contextWindowSeconds)
        lock.lock()
        defer { lock.unlock() }
        return history.filter { $0.timestamp >= cutoff }.map(\.text)
    }

    func correct(text: String, context: ScreenContext) async -> CorrectionResult {
        let recentHistory = getRecentHistory()
        do {
            let corrected = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await self.runClaude(text: text, context: context, previousSegments: recentHistory)
            }
            let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                addToHistory(text)
                return CorrectionResult(original: text, corrected: text, status: .error("empty response"))
            }
            let status: CorrectionStatus = trimmed == text ? .unchanged : .corrected
            addToHistory(trimmed)
            return CorrectionResult(original: text, corrected: trimmed, status: status)
        } catch is CancellationError {
            addToHistory(text)
            return CorrectionResult(original: text, corrected: text, status: .timeout)
        } catch {
            addToHistory(text)
            return CorrectionResult(original: text, corrected: text, status: .error(error.localizedDescription))
        }
    }

    private func runClaude(text: String, context: ScreenContext, previousSegments: [String]) async throws -> String {
        var prompt = """
            You are a speech-to-text corrector. The input is raw voice transcription.

            ## Rules
            - Fix misrecognized words using screen context (app name, window title, screenshots, URL) and camera photos
            - Camera photos show the user's physical environment. Use visible objects, text, or labels to improve transcription accuracy (e.g. food names, product labels, handwritten notes)
            - Add appropriate punctuation (。、！？) for natural Japanese text
            - Remove filler words (えーと, あの, まあ, うーん, etc.) and meaningless repetitions
            - Fix false starts and stutters into clean sentences
            - Keep the speaker's intended meaning intact
            - Technical terms, proper nouns, and variable/function names should match what's visible on screen
            - Output ONLY the corrected text. No explanations, no quotes, no prefixes.

            """
        if !previousSegments.isEmpty {
            prompt += "## Previous conversation (for context)\n"
            for segment in previousSegments {
                prompt += "- \(segment)\n"
            }
            prompt += "\n"
        }
        prompt += """
            ## Transcription to correct
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
        for camera in context.cameras {
            prompt += "### Camera\n"
            if let path = camera.imagePath {
                prompt += "Photo (read this file): \(path)\n"
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
