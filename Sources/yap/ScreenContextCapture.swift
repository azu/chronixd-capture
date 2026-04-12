@preconcurrency import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit

// MARK: - ScreenContext

struct DisplayContext: Sendable {
    let displayID: CGDirectDisplayID
    let appName: String?
    let windowTitle: String?
    let url: String?
    let screenshotPath: String?
    /// Whether this display appears to be playing media (video/streaming site).
    let isPlayingMedia: Bool
    /// Whether this display has the key window (user focus).
    let isFocused: Bool
    /// Process ID of the frontmost app on this display.
    let pid: Int32
    /// Seconds since last user input (keyboard/mouse). Only set for focused display.
    let idleSeconds: Double?
    /// Normalized scroll position (0.0–1.0) of the frontmost scroll area. Only set for focused display.
    let scrollPosition: Double?
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

struct CameraContext: Sendable {
    let deviceID: String
    let imagePath: String?
}

struct ScreenContext: Sendable {
    let displays: [DisplayContext]
    let cameras: [CameraContext]
    let timestamp: Date
}

// MARK: - ScreenContextCapture

final class ScreenContextCapture: Sendable {
    let mediaTitleKeywords: [String]

    init(mediaTitleKeywords: [String] = defaultMediaTitleKeywords) {
        self.mediaTitleKeywords = mediaTitleKeywords
    }

    /// Capture screen context with screenshots and metadata (no OCR).
    @MainActor
    func capture() async throws -> ScreenContext {
        let windowsByDisplay = captureVisibleWindows()
        let focusedDisplayID = activeDisplayID()
        let displays = try await captureAllDisplays(windowsByDisplay: windowsByDisplay, mediaTitleKeywords: mediaTitleKeywords, focusedDisplayID: focusedDisplayID)
        return ScreenContext(displays: displays, cameras: [], timestamp: Date())
    }

    func isMediaTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let lowered = title.lowercased()
        return mediaTitleKeywords.contains { lowered.contains($0.lowercased()) }
    }
}

// MARK: - Window Info Capture

struct WindowEntry {
    let appName: String
    let windowTitle: String?
    let pid: Int32
}

/// Get the top-most user window per display using CGWindowListCopyWindowInfo.
/// Returns a dictionary keyed by display ID.
func captureVisibleWindows() -> [CGDirectDisplayID: WindowEntry] {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return [:]
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    var seenDisplays = Set<CGDirectDisplayID>()
    var results: [CGDirectDisplayID: WindowEntry] = [:]

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
                results[displayID] = WindowEntry(appName: appName, windowTitle: windowTitle, pid: pid)
            }
            continue
        }
        seenDisplays.insert(displayID)

        // Use AX fallback if title is nil or empty
        var resolvedTitle = windowTitle
        if !hasTitle {
            resolvedTitle = axWindowTitle(for: pid)
        }

        results[displayID] = WindowEntry(appName: appName, windowTitle: resolvedTitle, pid: pid)
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

/// Known browser app names.
private let browserAppNames = Set([
    "Firefox", "Safari",
    "Google Chrome", "Google Chrome Dev", "Google Chrome Canary", "Google Chrome Beta",
    "Chromium",
    "Arc", "Brave Browser", "Microsoft Edge", "Orion", "Vivaldi", "Opera",
])

/// Extract URL from a browser's address bar via Accessibility API.
/// First tries AXComboBox/AXTextField (address bar value), then falls back to
/// AXWebArea's AXURL attribute which works reliably for Firefox and Arc.
func axBrowserURL(for pid: Int32) -> String? {
    let axApp = AXUIElementCreateApplication(pid)

    // Strategy 1: Find URL bar (AXComboBox/AXTextField/AXStaticText)
    func findURLBar(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == "AXComboBox" || role == "AXTextField" || role == "AXStaticText" {
            // For AXStaticText (Arc), check identifier to prefer the URL bar
            if role == "AXStaticText" {
                var identRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identRef)
                let ident = identRef as? String ?? ""
                // Arc's URL bar has identifier "commandBarPlaceholderTextField"
                guard ident.contains("commandBar") || ident.isEmpty else { return nil }
            }
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let value = valueRef as? String, looksLikeURL(value) {
                return value
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let url = findURLBar(child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    // Strategy 2: Find AXWebArea's AXURL attribute (works for Firefox, Arc, etc.)
    func findWebAreaURL(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == "AXWebArea" {
            var urlRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef)
            if let url = urlRef as? URL {
                return url.absoluteString
            }
            if let urlString = urlRef as? String, looksLikeURL(urlString) {
                return urlString
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let url = findWebAreaURL(child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    return findURLBar(axApp) ?? findWebAreaURL(axApp)
}

private func looksLikeURL(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    // Matches "domain.tld/..." or "scheme://..."
    return trimmed.contains("://") || (trimmed.contains(".") && !trimmed.contains(" ") && trimmed.count > 5)
}

/// Returns the CGDirectDisplayID of the display containing the frontmost application's window.
/// Uses NSWorkspace.frontmostApplication to get the actual focused app, then finds its
/// topmost window via CGWindowList to determine the display.
@MainActor
func activeDisplayID() -> CGDirectDisplayID {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        return CGMainDisplayID()
    }
    let frontPID = frontApp.processIdentifier

    // Find the frontmost app's topmost window to determine its display
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return CGMainDisplayID()
    }

    for window in windowList {
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid == frontPID else { continue }
        guard let layer = window[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat,
              let h = bounds["Height"] as? CGFloat else { continue }

        let candidatePoints = [
            CGPoint(x: x + w / 2, y: y + h / 2),
            CGPoint(x: x + 1, y: y + 1),
        ]
        for point in candidatePoints {
            var displayID: CGDirectDisplayID = 0
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(point, 1, &displayID, &count)
            if count > 0 { return displayID }
        }

        // Fullscreen fallback
        let windowRect = CGRect(x: x, y: y, width: w, height: h)
        var allDisplays = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(8, &allDisplays, &displayCount)
        for i in 0..<Int(displayCount) {
            let displayBounds = CGDisplayBounds(allDisplays[i])
            if abs(windowRect.width - displayBounds.width) < 10 && abs(windowRect.height - displayBounds.height) < 10 {
                return allDisplays[i]
            }
        }
    }

    return CGMainDisplayID()
}

// MARK: - OCR Screen Capture

/// Capture all displays and return per-display context with matched window info.
private func captureAllDisplays(
    windowsByDisplay: [CGDirectDisplayID: WindowEntry],
    mediaTitleKeywords: [String],
    focusedDisplayID: CGDirectDisplayID
) async throws -> [DisplayContext] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !content.displays.isEmpty else { return [] }

    // Create timestamped directory: /tmp/chronixd-capture/YYYYMMDD-HHmmss/
    let yapDir = NSTemporaryDirectory() + "chronixd-capture/"
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

        // Extract URL from browser address bar
        let url: String? = if let info = windowInfo, browserAppNames.contains(info.appName) {
            axBrowserURL(for: info.pid)
        } else {
            nil
        }

        // Capture idle time and scroll position for focused display
        let isFocused = display.displayID == focusedDisplayID
        let idleSeconds: Double? = if isFocused {
            systemIdleSeconds()
        } else {
            nil
        }
        let scrollPosition: Double? = if isFocused, let info = windowInfo {
            axScrollPosition(for: info.pid)
        } else {
            nil
        }

        results.append(DisplayContext(
            displayID: display.displayID,
            appName: windowInfo?.appName,
            windowTitle: windowInfo?.windowTitle,
            url: url,
            screenshotPath: screenshotPath,
            isPlayingMedia: isMedia,
            isFocused: isFocused,
            pid: windowInfo?.pid ?? 0,
            idleSeconds: idleSeconds,
            scrollPosition: scrollPosition
        ))
    }

    return results
}

/// Maximum screenshot width. Images are scaled down to save tokens when sent to Claude.
private let maxScreenshotWidth = 1280

private func captureDisplayImage(_ display: SCDisplay) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    // Scale down to maxScreenshotWidth, preserving aspect ratio
    let scale = min(1.0, Double(maxScreenshotWidth) / Double(display.width))
    config.width = Int(Double(display.width) * scale)
    config.height = Int(Double(display.height) * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.capturesAudio = false

    return try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: config
    )
}

/// Returns seconds since last keyboard or mouse event.
func systemIdleSeconds() -> Double {
    let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
    let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
    let scroll = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
    return min(mouse, key, click, scroll)
}

/// Extract normalized vertical scroll position (0.0–1.0) from the frontmost window's scroll area.
/// Strategy 1: AXVerticalScrollBar AXValue (native apps like Safari, Xcode).
/// Strategy 2: Compare AXScrollArea frame vs content child frame (Firefox, Chromium-based browsers).
func axScrollPosition(for pid: Int32) -> Double? {
    let axApp = AXUIElementCreateApplication(pid)

    var focusedWindowRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
    guard let focusedWindow = focusedWindowRef else { return nil }

    // Find largest AXScrollArea (main content area)
    func findLargestScrollArea(_ element: AXUIElement, depth: Int = 0) -> (AXUIElement, CGRect)? {
        guard depth < 8 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        var best: (AXUIElement, CGRect)?
        if role == "AXScrollArea" {
            if let rect = axFrame(element), rect.width > 100 && rect.height > 100 {
                best = (element, rect)
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return best }
        for child in children {
            if let found = findLargestScrollArea(child, depth: depth + 1) {
                if best == nil || found.1.width * found.1.height > best!.1.width * best!.1.height {
                    best = found
                }
            }
        }
        return best
    }

    // swiftlint:disable:next force_cast
    guard let (scrollArea, scrollAreaRect) = findLargestScrollArea(focusedWindow as! AXUIElement) else { return nil }

    // Strategy 1: AXVerticalScrollBar (native apps)
    var vScrollRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(scrollArea, "AXVerticalScrollBar" as CFString, &vScrollRef) == .success,
       let vScroll = vScrollRef {
        var valueRef: CFTypeRef?
        // swiftlint:disable:next force_cast
        AXUIElementCopyAttributeValue(vScroll as! AXUIElement, kAXValueAttribute as CFString, &valueRef)
        if let value = valueRef as? Double { return value }
        if let value = valueRef as? NSNumber { return value.doubleValue }
    }

    // Strategy 2: Content child position relative to scroll area (Firefox, etc.)
    // Walk into AXWebArea children to find the scrollable content element
    func findContentRect(in element: AXUIElement, depth: Int = 0) -> CGRect? {
        guard depth < 4 else { return nil }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let childRole = roleRef as? String ?? ""

            if let childRect = axFrame(child), childRect.height > scrollAreaRect.height {
                return childRect
            }
            // Recurse into AXWebArea
            if childRole == "AXWebArea" {
                if let found = findContentRect(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    if let contentRect = findContentRect(in: scrollArea) {
        let maxScroll = contentRect.height - scrollAreaRect.height
        guard maxScroll > 0 else { return 0 }
        let scrollOffset = scrollAreaRect.origin.y - contentRect.origin.y
        return max(0, min(1, scrollOffset / maxScroll))
    }

    return nil
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &ref)
    guard let val = ref else { return nil }
    var rect = CGRect.zero
    // swiftlint:disable:next force_cast
    AXValueGetValue(val as! AXValue, .cgRect, &rect)
    return rect
}

private func cleanupOldCaptures(in directory: String, keep: Int) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
    // Only clean up timestamped directories (YYYYMMDD-HHmmss format), not session UUID dirs
    let timestamped = entries.filter { $0.count == 15 && $0.contains("-") && $0.first?.isNumber == true }
    let sorted = timestamped.sorted()
    if sorted.count > keep {
        for entry in sorted.prefix(sorted.count - keep) {
            try? fm.removeItem(atPath: directory + entry)
        }
    }
}

