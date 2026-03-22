import Foundation
import MLXLMCommon

// MARK: - ContextExplanation

struct ContextExplanation: Sendable {
    let activity: String
    let summary: String
}

// MARK: - ContextExplainer Protocol

protocol ContextExplainer: Sendable {
    func explain(context: ScreenContext, locale: Locale) async -> ContextExplanation?
}

// MARK: - ClaudeContextExplainer

final class ClaudeContextExplainer: ContextExplainer, @unchecked Sendable {
    static let timeoutSeconds: UInt64 = 30
    let model: String

    init(model: String = "haiku") {
        self.model = model
    }

    func explain(context: ScreenContext, locale: Locale) async -> ContextExplanation? {
        do {
            let raw = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await self.runClaude(context: context, locale: locale)
            }
            return Self.parseResponse(raw)
        } catch {
            return nil
        }
    }

    private func runClaude(context: ScreenContext, locale: Locale) async throws -> String {
        let lang = Locale.current.localizedString(forIdentifier: locale.identifier(.bcp47)) ?? locale.identifier(.bcp47)
        var prompt = """
            Analyze the screenshots and camera photos to determine what the user is currently doing.
            Respond in \(lang).

            """
        prompt += "## Screen Context\n\n"
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

        let jsonSchema = #"{"type":"object","properties":{"activity":{"type":"string","description":"What the user is doing (e.g. coding, cooking, reading, browsing, meeting)"},"summary":{"type":"string","description":"One-line summary of the current situation"}},"required":["activity","summary"]}"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
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

    private static func parseResponse(_ raw: String) -> ContextExplanation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let structured = json["structured_output"] as? [String: Any],
           let activity = structured["activity"] as? String,
           let summary = structured["summary"] as? String {
            return ContextExplanation(activity: activity, summary: summary)
        }
        return nil
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

// MARK: - MLXContextExplainer

final class MLXContextExplainer: ContextExplainer, @unchecked Sendable {
    private let modelID: String
    private var modelContext: ModelContext?

    init(modelID: String? = nil) {
        self.modelID = modelID ?? "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
    }

    func loadModelIfNeeded() async throws {
        if modelContext == nil {
            modelContext = try await loadModel(id: modelID)
        }
    }

    func explain(context: ScreenContext, locale: Locale) async -> ContextExplanation? {
        do {
            let session = try await newSession()
            let lang = Locale.current.localizedString(forIdentifier: locale.identifier(.bcp47)) ?? locale.identifier(.bcp47)
            let prompt = """
                Analyze the screenshots and camera photos. What is the user doing?
                Output EXACTLY 2 lines:
                ACTIVITY: what user is doing
                SUMMARY: one-line situation summary
                Respond in \(lang).

                """
            var images: [UserInput.Image] = context.displays.compactMap { display in
                guard let path = display.screenshotPath else { return nil }
                return .url(URL(fileURLWithPath: path))
            }
            for camera in context.cameras {
                if let path = camera.imagePath {
                    images.append(.url(URL(fileURLWithPath: path)))
                }
            }

            let response: String
            if images.isEmpty {
                response = try await session.respond(to: prompt)
            } else {
                response = try await session.respond(to: prompt, images: images, videos: [])
            }

            return Self.parseResponse(response)
        } catch {
            return nil
        }
    }

    private func newSession() async throws -> ChatSession {
        if modelContext == nil {
            modelContext = try await loadModel(id: modelID)
        }
        return ChatSession(
            modelContext!,
            processing: UserInput.Processing(resize: CGSize(width: 512, height: 512))
        )
    }

    private static func parseResponse(_ raw: String) -> ContextExplanation? {
        let lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var activity: String?
        var summary: String?
        for line in lines {
            if line.hasPrefix("ACTIVITY:") {
                activity = line.replacingOccurrences(of: "ACTIVITY:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("SUMMARY:") {
                summary = line.replacingOccurrences(of: "SUMMARY:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        guard let activity, let summary else { return nil }
        return ContextExplanation(activity: activity, summary: summary)
    }
}
