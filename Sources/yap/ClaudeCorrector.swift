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
            let raw = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await self.runClaude(text: text, context: context, previousSegments: recentHistory)
            }
            let parsed = Self.parseResponse(raw)
            let correctedText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if correctedText.isEmpty {
                addToHistory(text)
                return CorrectionResult(original: text, corrected: text, status: .error("empty response"), activity: nil, summary: nil)
            }
            let status: CorrectionStatus = correctedText == text ? .unchanged : .corrected
            addToHistory(correctedText)
            return CorrectionResult(original: text, corrected: correctedText, status: status, activity: parsed.activity, summary: parsed.summary)
        } catch is CancellationError {
            addToHistory(text)
            return CorrectionResult(original: text, corrected: text, status: .timeout, activity: nil, summary: nil)
        } catch {
            addToHistory(text)
            return CorrectionResult(original: text, corrected: text, status: .error(error.localizedDescription), activity: nil, summary: nil)
        }
    }

    private struct ParsedResponse {
        let text: String
        let activity: String?
        let summary: String?
    }

    /// Parse JSON response from claude -p. Falls back to raw text on parse failure.
    private static func parseResponse(_ raw: String) -> ParsedResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // claude --output-format json wraps result in {"result": "...", ...}
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedResponse(text: trimmed, activity: nil, summary: nil)
        }
        // The structured output may be in "result" (string containing JSON) or at top level
        if let resultStr = json["result"] as? String,
           let resultData = resultStr.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            return ParsedResponse(
                text: inner["text"] as? String ?? resultStr,
                activity: inner["activity"] as? String,
                summary: inner["summary"] as? String
            )
        }
        // Top-level JSON with text/activity/summary
        if let text = json["text"] as? String {
            return ParsedResponse(
                text: text,
                activity: json["activity"] as? String,
                summary: json["summary"] as? String
            )
        }
        // Fallback: use result as plain text
        if let result = json["result"] as? String {
            return ParsedResponse(text: result, activity: nil, summary: nil)
        }
        return ParsedResponse(text: trimmed, activity: nil, summary: nil)
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
            - Also analyze the screen and camera context to determine what the user is doing
            - Respond in the same language as the user's speech for text, activity, and summary fields

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
        let jsonSchema = """
            {"type":"object","properties":{"text":{"type":"string","description":"Corrected transcription text"},"activity":{"type":"string","description":"What the user is doing (e.g. coding, cooking, reading, browsing, meeting)"},"summary":{"type":"string","description":"One-line summary of the current situation"}},"required":["text","activity","summary"]}
            """
        process.arguments = [
            "claude", "-p",
            "--output-format", "json",
            "--json-schema", jsonSchema,
            "--model", model,
            "--no-session-persistence",
            "--disable-slash-commands",
            "--allowedTools", "Read",
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
