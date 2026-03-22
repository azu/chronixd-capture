import Foundation
import MLXLMCommon

/// Corrects transcription using an MLX Vision Language Model (e.g. Qwen2.5-VL).
/// Processes screenshots directly without OCR.
final class MLXCorrector: Corrector, @unchecked Sendable {
    private let lock = NSLock()
    static let defaultModelID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"

    private let modelID: String
    private var modelContext: ModelContext?

    /// How far back to include previous segments as context.
    static let contextWindowSeconds: TimeInterval = 600 // 10 minutes
    private var history: [(text: String, timestamp: Date)] = []

    init(modelID: String? = nil) {
        self.modelID = modelID ?? Self.defaultModelID
    }

    /// Load the model eagerly. Call at startup to avoid delays on first correction.
    func loadModelIfNeeded() async throws {
        if modelContext == nil {
            modelContext = try await loadModel(id: modelID)
        }
    }

    /// Create a fresh ChatSession per correction to avoid history contamination.
    private func newSession() async throws -> ChatSession {
        if modelContext == nil {
            modelContext = try await loadModel(id: modelID)
        }
        return ChatSession(
            modelContext!,
            processing: UserInput.Processing(resize: CGSize(width: 512, height: 512))
        )
    }

    func correct(text: String, context: ScreenContext) async -> CorrectionResult {
        do {
            let session = try await newSession()
            let prompt = buildPrompt(text: text, context: context)
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


            let corrected = response.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: CorrectionStatus = corrected == text ? .unchanged : .corrected
            addToHistory(corrected)
            return CorrectionResult(original: text, corrected: corrected, status: status, activity: nil, summary: nil)
        } catch {
            addToHistory(text)
            return CorrectionResult(original: text, corrected: text, status: .error(error.localizedDescription), activity: nil, summary: nil)
        }
    }

    private func buildPrompt(text: String, context: ScreenContext) -> String {
        var prompt = """
            Fix this voice transcription using the screenshots. \
            Fix misrecognized words, add punctuation, remove fillers. \
            Output ONLY the corrected text. No quotes, no brackets, no explanations.

            """

        let recentHistory = getRecentHistory()
        if !recentHistory.isEmpty {
            prompt += "Previous conversation:\n"
            for segment in recentHistory {
                prompt += "- \(segment)\n"
            }
            prompt += "\n"
        }

        prompt += "Transcription to correct:\n\(text)\n\nScreen context:\n"
        for display in context.displays {
            prompt += display.isFocused ? "Focused Display:\n" : "Display:\n"
            if let appName = display.appName {
                prompt += "Application: \(appName)\n"
            }
            if let windowTitle = display.windowTitle {
                prompt += "Window: \(windowTitle)\n"
            }
            if let url = display.url {
                prompt += "URL: \(url)\n"
            }
        }

        return prompt
    }

    private func addToHistory(_ text: String) {
        let now = Date()
        history.append((text: text, timestamp: now))
        let cutoff = now.addingTimeInterval(-Self.contextWindowSeconds)
        history.removeAll { $0.timestamp < cutoff }
    }

    private func getRecentHistory() -> [String] {
        let cutoff = Date().addingTimeInterval(-Self.contextWindowSeconds)
        return history.filter { $0.timestamp >= cutoff }.map(\.text)
    }
}
