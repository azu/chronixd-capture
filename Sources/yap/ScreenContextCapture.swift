@preconcurrency import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit
import Vision

// MARK: - ScreenContext

struct ScreenContext: Sendable {
    let appName: String?
    let windowTitle: String?
    let focusedElement: String?
    let ocrText: String
    let timestamp: Date
}

// MARK: - ScreenContextCapture

final class ScreenContextCapture: Sendable {
    static let maxOCRLength = 2000

    @MainActor
    func capture() async throws -> ScreenContext {
        let info = captureAccessibilityInfo()
        let text = try await captureAllDisplaysOCRText()
        return ScreenContext(
            appName: info.appName,
            windowTitle: info.windowTitle,
            focusedElement: info.focusedElement,
            ocrText: text,
            timestamp: Date()
        )
    }
}

// MARK: - Accessibility Info

private struct AccessibilityInfo {
    let appName: String?
    let windowTitle: String?
    let focusedElement: String?
}

@MainActor
private func captureAccessibilityInfo() -> AccessibilityInfo {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return AccessibilityInfo(appName: nil, windowTitle: nil, focusedElement: nil)
    }
    let appName = app.localizedName

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var windowValue: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue)

    var windowTitle: String?
    if let window = windowValue {
        var titleValue: CFTypeRef?
        // swiftlint:disable:next force_cast
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        windowTitle = titleValue as? String
    }

    var focusedValue: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedValue)
    var focusedElement: String?
    if let focused = focusedValue {
        var valueRef: CFTypeRef?
        // swiftlint:disable:next force_cast
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &valueRef)
        if let value = valueRef as? String {
            focusedElement = String(value.prefix(500))
        }
    }

    return AccessibilityInfo(appName: appName, windowTitle: windowTitle, focusedElement: focusedElement)
}

// MARK: - OCR Screen Capture

/// Capture OCR text from all connected displays in parallel, concatenated with display separators.
private func captureAllDisplaysOCRText() async throws -> String {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !content.displays.isEmpty else { return "" }

    let texts = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
        for display in content.displays {
            group.addTask {
                try await captureOCRTextForDisplay(display)
            }
        }
        var results: [String] = []
        for try await text in group {
            if !text.isEmpty {
                results.append(text)
            }
        }
        return results
    }

    let combined = texts.joined(separator: "\n")
    return String(combined.prefix(ScreenContextCapture.maxOCRLength))
}

private func captureOCRTextForDisplay(_ display: SCDisplay) async throws -> String {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(display.width)
    config.height = Int(display.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.capturesAudio = false

    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: config
    )

    return try await performOCR(on: image)
}

private func performOCR(on image: CGImage) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            let truncated = String(text.prefix(ScreenContextCapture.maxOCRLength))
            continuation.resume(returning: truncated)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
