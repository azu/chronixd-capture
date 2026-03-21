@preconcurrency import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit
import Vision

// MARK: - ScreenContext

struct DisplayContext: Sendable {
    let displayID: CGDirectDisplayID
    let appName: String?
    let windowTitle: String?
    let ocrText: String
    let screenshotPath: String?
}

struct ScreenContext: Sendable {
    let displays: [DisplayContext]
    let focusedElement: String?
    let timestamp: Date
}

// MARK: - ScreenContextCapture

final class ScreenContextCapture: Sendable {
    static let maxOCRLength = 2000

    /// Capture screen context with Vision OCR (for local mode).
    @MainActor
    func capture() async throws -> ScreenContext {
        let windowsByDisplay = captureVisibleWindows()
        let focusedElement = captureFocusedElement()
        let displays = try await captureAllDisplays(ocr: true, windowsByDisplay: windowsByDisplay)
        return ScreenContext(
            displays: displays,
            focusedElement: focusedElement,
            timestamp: Date()
        )
    }

    /// Capture screen context with screenshots only, no OCR (for claude mode).
    @MainActor
    func captureWithScreenshots() async throws -> ScreenContext {
        let windowsByDisplay = captureVisibleWindows()
        let focusedElement = captureFocusedElement()
        let displays = try await captureAllDisplays(ocr: false, windowsByDisplay: windowsByDisplay)
        return ScreenContext(
            displays: displays,
            focusedElement: focusedElement,
            timestamp: Date()
        )
    }
}

// MARK: - Window Info Capture

/// Get the top-most user window per display using CGWindowListCopyWindowInfo.
/// Returns a dictionary keyed by display ID.
private func captureVisibleWindows() -> [CGDirectDisplayID: (appName: String, windowTitle: String?)] {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return [:]
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    var seenDisplays = Set<CGDirectDisplayID>()
    var results: [CGDirectDisplayID: (appName: String, windowTitle: String?)] = [:]

    for window in windowList {
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
        guard let appName = window[kCGWindowOwnerName as String] as? String else { continue }
        if ["WindowManager", "Control Center", "Notification Center"].contains(appName) { continue }

        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat else { continue }
        let point = CGPoint(x: x + 1, y: y + 1)
        var displayCount: UInt32 = 0
        var displayID: CGDirectDisplayID = 0
        CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount)
        guard displayCount > 0 else { continue }

        // One window per display (windows are ordered front-to-back)
        guard !seenDisplays.contains(displayID) else { continue }
        seenDisplays.insert(displayID)

        let windowTitle = window[kCGWindowName as String] as? String
        results[displayID] = (appName: appName, windowTitle: windowTitle)
    }

    return results
}

/// Get the focused UI element text from the frontmost app via Accessibility API.
@MainActor
private func captureFocusedElement() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedValue: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedValue)
    guard let focused = focusedValue else { return nil }
    var valueRef: CFTypeRef?
    // swiftlint:disable:next force_cast
    AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &valueRef)
    guard let value = valueRef as? String else { return nil }
    return String(value.prefix(500))
}

// MARK: - OCR Screen Capture

/// Capture all displays and return per-display context with matched window info.
private func captureAllDisplays(
    ocr: Bool,
    windowsByDisplay: [CGDirectDisplayID: (appName: String, windowTitle: String?)]
) async throws -> [DisplayContext] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !content.displays.isEmpty else { return [] }

    // Create timestamped directory: /tmp/yap/YYYYMMDD-HHmmss/
    let yapDir = NSTemporaryDirectory() + "yap/"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let dir = yapDir + formatter.string(from: Date()) + "/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Keep only the most recent 60 capture directories
    cleanupOldCaptures(in: yapDir, keep: 60)

    var results: [DisplayContext] = []

    for display in content.displays {
        let image = try await captureDisplayImage(display)

        // Save screenshot
        var screenshotPath: String?
        let path = dir + "display-\(display.displayID).png"
        if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) {
                screenshotPath = path
            }
        }

        // OCR
        var ocrText = ""
        if ocr {
            let text = try await performOCR(on: image)
            ocrText = String(text.prefix(ScreenContextCapture.maxOCRLength))
        }

        // Match window info for this display
        let windowInfo = windowsByDisplay[display.displayID]

        results.append(DisplayContext(
            displayID: display.displayID,
            appName: windowInfo?.appName,
            windowTitle: windowInfo?.windowTitle,
            ocrText: ocrText,
            screenshotPath: screenshotPath
        ))
    }

    return results
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
