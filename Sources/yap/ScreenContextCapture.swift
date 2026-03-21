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
    /// File paths to screenshot PNGs (one per display). Used by claude mode.
    let screenshotPaths: [String]
    let timestamp: Date
}

// MARK: - ScreenContextCapture

final class ScreenContextCapture: Sendable {
    static let maxOCRLength = 2000

    /// Capture screen context with Vision OCR (for local mode).
    @MainActor
    func capture() async throws -> ScreenContext {
        let info = captureAccessibilityInfo()
        let (text, paths) = try await captureAllDisplays(ocr: true)
        return ScreenContext(
            appName: info.appName,
            windowTitle: info.windowTitle,
            focusedElement: info.focusedElement,
            ocrText: text,
            screenshotPaths: paths,
            timestamp: Date()
        )
    }

    /// Capture screen context with screenshots only, no OCR (for claude mode).
    @MainActor
    func captureWithScreenshots() async throws -> ScreenContext {
        let info = captureAccessibilityInfo()
        let (_, paths) = try await captureAllDisplays(ocr: false)
        return ScreenContext(
            appName: info.appName,
            windowTitle: info.windowTitle,
            focusedElement: info.focusedElement,
            ocrText: "",
            screenshotPaths: paths,
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

/// Capture all displays. Returns (ocrText, screenshotPaths).
/// When `ocr` is false, OCR is skipped and ocrText is empty.
private func captureAllDisplays(ocr: Bool) async throws -> (String, [String]) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !content.displays.isEmpty else { return ("", []) }

    var ocrResults: [String] = []
    var paths: [String] = []

    // Create timestamped directory: /tmp/yap/YYYYMMDD-HHmmss/
    let yapDir = NSTemporaryDirectory() + "yap/"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let dir = yapDir + formatter.string(from: Date()) + "/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Keep only the most recent 60 capture directories
    cleanupOldCaptures(in: yapDir, keep: 60)

    for display in content.displays {
        let image = try await captureDisplayImage(display)

        // Save screenshot to timestamped directory
        let path = dir + "display-\(display.displayID).png"
        if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) {
                paths.append(path)
            }
        }

        if ocr {
            let text = try await performOCR(on: image)
            if !text.isEmpty {
                ocrResults.append(text)
            }
        }
    }

    let combined = ocrResults.joined(separator: "\n")
    let ocrText = String(combined.prefix(ScreenContextCapture.maxOCRLength))
    return (ocrText, paths)
}

private func captureDisplayImage(_ display: SCDisplay) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(display.width)
    config.height = Int(display.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.capturesAudio = false

    return try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: config
    )
}

private func cleanupOldCaptures(in directory: String, keep: Int) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
    let sorted = entries.sorted()
    if sorted.count > keep {
        for entry in sorted.prefix(sorted.count - keep) {
            try? fm.removeItem(atPath: directory + entry)
        }
    }
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
