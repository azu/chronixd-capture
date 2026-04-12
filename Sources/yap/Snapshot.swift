import ApplicationServices
import ArgumentParser
import Foundation
import ScreenCaptureKit

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture a one-time screen context snapshot. Writes to data-dir and outputs NDJSON to stdout."
    )

    @Option(name: .long, help: "Data directory. If provided, records are also written to disk.")
    var dataDir: String?

    @MainActor
    func run() async throws {
        guard AXIsProcessTrusted() else {
            throw CleanExit.message("Accessibility permission denied.")
        }

        let windowsByDisplay = captureVisibleWindows()
        let focusedDisplayID = activeDisplayID()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let capture = ScreenContextCapture()

        // Set up store if data-dir provided
        var store: CaptureStore?
        if let dataDir {
            let s = CaptureStore(dataDir: dataDir)
            try s.setup()
            store = s
        }

        var records: [any CaptureRecord] = []

        // Get all displays
        var allDisplays = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(8, &allDisplays, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = allDisplays[i]
            let windowInfo = windowsByDisplay[displayID]
            let isFocused = displayID == focusedDisplayID

            let url: String? = if let info = windowInfo, browserAppNames.contains(info.appName) {
                axBrowserURL(for: info.pid)
            } else {
                nil
            }

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

            let titleMatch: Bool = if let title = windowInfo?.windowTitle {
                capture.isMediaTitle(title)
            } else {
                false
            }
            let appMatch: Bool = if let appName = windowInfo?.appName {
                defaultMediaAppNames.contains { appName.localizedCaseInsensitiveCompare($0) == .orderedSame }
            } else {
                false
            }

            let hookContext: String? = if isFocused, let dataDir {
                runAppContextHook(
                    dataDir: dataDir,
                    appName: windowInfo?.appName ?? "Unknown",
                    windowTitle: windowInfo?.windowTitle ?? "",
                    pid: windowInfo?.pid ?? 0
                )
            } else {
                nil
            }

            let recordID = UUID().uuidString.prefix(12).lowercased()
            let record = ScreenshotRecord(
                id: String(recordID),
                unixTimeMs: nowMs,
                url: normalizeURL(url),
                app: windowInfo?.appName ?? "Unknown",
                title: windowInfo?.windowTitle,
                isFocused: isFocused,
                isPlayingMedia: titleMatch || appMatch,
                appContext: hookContext,
                idleSeconds: idleSeconds.map { ($0 * 10).rounded() / 10 },
                scrollPosition: scrollPosition.map { ($0 * 1000).rounded() / 1000 }
            )
            records.append(record)
        }

        // Write to store
        if let store, !records.isEmpty {
            try store.writeCapture(records: records, timestamp: Date())
        }

        // Output to stdout
        for record in records {
            let line = try CaptureRecordCoder.encode(record)
            print(line)
        }
    }
}

// Re-expose browser app names for URL extraction check
private let browserAppNames = Set([
    "Firefox", "Safari",
    "Google Chrome", "Google Chrome Dev", "Google Chrome Canary", "Google Chrome Beta",
    "Chromium",
    "Arc", "Brave Browser", "Microsoft Edge", "Orion", "Vivaldi", "Opera",
])
