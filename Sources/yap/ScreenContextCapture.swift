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
    /// Whether this display appears to be playing media (video/streaming site).
    let isPlayingMedia: Bool
    /// Whether this display has the key window (user focus).
    let isFocused: Bool
}

/// Default keywords to detect media/video sites in window titles.
let defaultMediaTitleKeywords = [
    "YouTube", "ニコニコ", "Netflix", "Prime Video", "Disney+",
    "Twitch", "TVer", "ABEMA", "U-NEXT", "Hulu", "dアニメ",
    "Crunchyroll", "Spotify", "Apple Music", "Apple TV",
]

/// App names that are always considered media players (regardless of window title).
let defaultMediaAppNames = [
    "Music", "ミュージック", "Spotify", "VLC", "IINA",
    "QuickTime Player", "TV", "Podcasts", "ポッドキャスト",
]

struct ScreenContext: Sendable {
    let displays: [DisplayContext]
    let timestamp: Date
}

// MARK: - ScreenContextCapture

final class ScreenContextCapture: Sendable {
    static let maxOCRLength = 2000

    let mediaTitleKeywords: [String]

    init(mediaTitleKeywords: [String] = defaultMediaTitleKeywords) {
        self.mediaTitleKeywords = mediaTitleKeywords
    }

    /// Capture screen context with Vision OCR (for local mode).
    @MainActor
    func capture() async throws -> ScreenContext {
        let windowsByDisplay = captureVisibleWindows()
        let focusedDisplayID = activeDisplayID()
        let displays = try await captureAllDisplays(ocr: true, windowsByDisplay: windowsByDisplay, mediaTitleKeywords: mediaTitleKeywords, focusedDisplayID: focusedDisplayID)
        return ScreenContext(displays: displays, timestamp: Date())
    }

    /// Capture screen context with screenshots only, no OCR (for claude mode).
    @MainActor
    func captureWithScreenshots() async throws -> ScreenContext {
        let windowsByDisplay = captureVisibleWindows()
        let focusedDisplayID = activeDisplayID()
        let displays = try await captureAllDisplays(ocr: false, windowsByDisplay: windowsByDisplay, mediaTitleKeywords: mediaTitleKeywords, focusedDisplayID: focusedDisplayID)
        return ScreenContext(displays: displays, timestamp: Date())
    }

    func isMediaTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let lowered = title.lowercased()
        return mediaTitleKeywords.contains { lowered.contains($0.lowercased()) }
    }
}

// MARK: - Window Info Capture

/// Get the top-most user window per display using CGWindowListCopyWindowInfo.
/// Returns a dictionary keyed by display ID.
func captureVisibleWindows() -> [CGDirectDisplayID: (appName: String, windowTitle: String?)] {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return [:]
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    var seenDisplays = Set<CGDirectDisplayID>()
    var results: [CGDirectDisplayID: (appName: String, windowTitle: String?)] = [:]

    for window in windowList {
        // layer 0 = normal windows, negative = fullscreen/spaces. Skip high layers (system overlays like Dock, menubar)
        guard let layer = window[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
        guard let appName = window[kCGWindowOwnerName as String] as? String else { continue }
        if ["WindowManager", "Window Server", "Control Center", "Notification Center", "Dock"].contains(appName) { continue }

        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat,
              let h = bounds["Height"] as? CGFloat else { continue }

        // Try center point first, then corners — fullscreen windows can have off-screen coordinates
        let candidatePoints = [
            CGPoint(x: x + w / 2, y: y + h / 2),
            CGPoint(x: x + 1, y: y + 1),
        ]
        var displayID: CGDirectDisplayID = 0
        var matched = false
        for point in candidatePoints {
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(point, 1, &displayID, &count)
            if count > 0 { matched = true; break }
        }

        // Fullscreen windows may have coordinates outside all displays.
        // Fall back to matching by window size ≈ display size.
        if !matched {
            let windowRect = CGRect(x: x, y: y, width: w, height: h)
            var allDisplays = [CGDirectDisplayID](repeating: 0, count: 8)
            var displayCount: UInt32 = 0
            CGGetActiveDisplayList(8, &allDisplays, &displayCount)
            for i in 0..<Int(displayCount) {
                let displayBounds = CGDisplayBounds(allDisplays[i])
                if abs(windowRect.width - displayBounds.width) < 10 && abs(windowRect.height - displayBounds.height) < 10 {
                    displayID = allDisplays[i]
                    matched = true
                    break
                }
            }
        }
        guard matched else { continue }

        let windowTitle = window[kCGWindowName as String] as? String

        // Skip windows with empty titles if we haven't seen this display yet —
        // a titled window from the same app may follow (e.g. Firefox toolbar vs content)
        let hasTitle = windowTitle != nil && !windowTitle!.isEmpty
        if seenDisplays.contains(displayID) {
            // Already have an entry. Only replace if the new one has a title and the old one doesn't.
            if hasTitle, let existing = results[displayID], (existing.windowTitle ?? "").isEmpty {
                results[displayID] = (appName: appName, windowTitle: windowTitle)
            }
            continue
        }
        seenDisplays.insert(displayID)

        // Use AX fallback if title is nil or empty
        var resolvedTitle = windowTitle
        if !hasTitle {
            resolvedTitle = axWindowTitle(for: pid)
        }

        results[displayID] = (appName: appName, windowTitle: resolvedTitle)
    }

    return results
}

/// Get the window title via Accessibility API for apps that don't expose kCGWindowName.
private func axWindowTitle(for pid: Int32) -> String? {
    let axApp = AXUIElementCreateApplication(pid)
    var windowsValue: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
    guard let windows = windowsValue as? [AXUIElement], let firstWindow = windows.first else {
        // Try focused window instead
        var focusedWindow: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard let window = focusedWindow else { return nil }
        var titleValue: CFTypeRef?
        // swiftlint:disable:next force_cast
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        return titleValue as? String
    }
    var titleValue: CFTypeRef?
    AXUIElementCopyAttributeValue(firstWindow, kAXTitleAttribute as CFString, &titleValue)
    return titleValue as? String
}

/// Returns the CGDirectDisplayID of the display containing the key window.
@MainActor
private func activeDisplayID() -> CGDirectDisplayID {
    if let mainScreen = NSScreen.main,
       let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        return screenNumber
    }
    return CGMainDisplayID()
}

// MARK: - OCR Screen Capture

/// Capture all displays and return per-display context with matched window info.
private func captureAllDisplays(
    ocr: Bool,
    windowsByDisplay: [CGDirectDisplayID: (appName: String, windowTitle: String?)],
    mediaTitleKeywords: [String],
    focusedDisplayID: CGDirectDisplayID
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

        let titleMatch: Bool = if let title = windowInfo?.windowTitle {
            mediaTitleKeywords.contains { title.localizedCaseInsensitiveContains($0) }
        } else {
            false
        }
        let appMatch: Bool = if let appName = windowInfo?.appName {
            defaultMediaAppNames.contains { appName.localizedCaseInsensitiveCompare($0) == .orderedSame }
        } else {
            false
        }
        let isMedia = titleMatch || appMatch

        results.append(DisplayContext(
            displayID: display.displayID,
            appName: windowInfo?.appName,
            windowTitle: windowInfo?.windowTitle,
            ocrText: ocrText,
            screenshotPath: screenshotPath,
            isPlayingMedia: isMedia,
            isFocused: display.displayID == focusedDisplayID
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
        request.recognitionLanguages = ["ja", "en"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
