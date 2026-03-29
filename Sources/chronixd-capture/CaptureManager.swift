import ApplicationServices
@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit
import Speech

// MARK: - CaptureManager

final class CaptureManager: @unchecked Sendable {
    struct Config: Sendable {
        var dataDir: String
        var interval: Int = 30
        var cameraIDs: [String] = []
        var ignoreApps: [String] = []
        var ignoreTitles: [String] = []
        var ignoreUrls: [String] = []
        var noDedup: Bool = false
        var locale: Locale = .current
    }

    enum State: Sendable {
        case stopped
        case capturing
        case muted
    }

    nonisolated(unsafe) var onStateChange: ((State) -> Void)?

    private let config: Config
    private let lock = NSLock()
    private nonisolated(unsafe) var state: State = .stopped
    private nonisolated(unsafe) var micCapture: MicrophoneCapture?
    private nonisolated(unsafe) var cameraCapture: CameraCapture?
    private nonisolated(unsafe) var captureTimerTask: Task<Void, Never>?
    private nonisolated(unsafe) var consumeTask: Task<Void, Never>?
    private nonisolated(unsafe) var mediaCheckTask: Task<Void, Never>?
    private nonisolated(unsafe) var analyzer: SpeechAnalyzer?

    init(config: Config) {
        self.config = config
    }

    @MainActor
    func start() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw CaptureManagerError.speechNotAvailable
        }

        // Prompt the system Accessibility dialog if not yet trusted
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw CaptureManagerError.accessibilityPermissionDenied
        }

        // Screen recording permission
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureManagerError.screenRecordingPermissionDenied
        }

        // Camera permission if needed
        if !config.cameraIDs.isEmpty {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw CaptureManagerError.cameraPermissionDenied
            }
        }

        // Locale check
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == config.locale.identifier(.bcp47) }) else {
            throw CaptureManagerError.unsupportedLocale
        }

        for loc in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: loc)
        }
        try await AssetInventory.reserve(locale: config.locale)

        // Set up transcriber
        let transcriber = SpeechTranscriber(
            locale: config.locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]

        // Download assets if needed
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier(.bcp47) == config.locale.identifier(.bcp47) }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        }

        let speechAnalyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = speechAnalyzer

        // Set up streaming input
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw CaptureManagerError.noCompatibleAudioFormat
        }

        let capture = try MicrophoneCapture(
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )
        self.micCapture = capture
        try capture.start()
        try await speechAnalyzer.start(inputSequence: inputSequence)

        // Set up CaptureStore
        let store = CaptureStore(dataDir: config.dataDir)
        try store.setup()

        // Set up camera capture
        let camCapture: CameraCapture? = if !config.cameraIDs.isEmpty {
            try CameraCapture(deviceIDs: config.cameraIDs)
        } else {
            nil
        }
        self.cameraCapture = camCapture

        // Thread-safe transcription buffer
        let transcriptionBuffer = TranscriptionBuffer()

        // Screen context capture
        let screenCapture = ScreenContextCapture()

        // Dedup state
        let dedupEnabled = !config.noDedup
        let dedupState = DedupState()

        // Copy ignore filters
        let ignoreAppPatterns = config.ignoreApps.isEmpty ? nil : config.ignoreApps
        let ignoreTitlePatterns = config.ignoreTitles.isEmpty ? nil : config.ignoreTitles
        let ignoreUrlPatterns = config.ignoreUrls.isEmpty ? nil : config.ignoreUrls

        updateState(.capturing)

        // Background task: poll media playback state every 2 seconds
        let muteCaptureRef = capture
        let weakSelf = self
        mediaCheckTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let shouldMute = await AudioOutputDetector.isMediaPlaying()
                if muteCaptureRef.isMuted != shouldMute {
                    muteCaptureRef.isMuted = shouldMute
                    weakSelf.updateState(shouldMute ? .muted : .capturing)
                }
            }
        }

        // Background task: consume transcriber results into buffer
        consumeTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let timeMs = Int64(Date().timeIntervalSince1970 * 1000)
                    transcriptionBuffer.append(TranscriptionSegment(unixTimeMs: timeMs, text: text))
                }
            } catch {
                // Transcriber ended
            }
        }

        // Background task: periodic capture timer
        let intervalSeconds = config.interval
        captureTimerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                let now = Date()
                let nowMs = Int64(now.timeIntervalSince1970 * 1000)

                // Capture screen context (with OCR + screenshots)
                let screenContext: ScreenContext
                do {
                    screenContext = try await screenCapture.capture()
                } catch {
                    NSLog("[chronixd-capture] Screen capture failed: %@", "\(error)")
                    continue
                }

                // Flush transcription buffer
                let segments = transcriptionBuffer.flush()

                // Build records
                var records: [any CaptureRecord] = []

                // Screenshot records for each display
                for display in screenContext.displays {
                    if let ignoreAppPatterns, let appName = display.appName,
                       ignoreAppPatterns.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                        continue
                    }
                    if let ignoreTitlePatterns, let title = display.windowTitle,
                       ignoreTitlePatterns.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                        continue
                    }
                    if let ignoreUrlPatterns, let url = display.url,
                       ignoreUrlPatterns.contains(where: { url.localizedCaseInsensitiveContains($0) }) {
                        continue
                    }
                    // Per-display dedup
                    if dedupEnabled {
                        let displayKey = DedupKey(
                            app: display.appName ?? "",
                            title: display.windowTitle ?? "",
                            url: display.url ?? ""
                        )
                        if dedupState.isDuplicate(displayID: display.displayID, key: displayKey) {
                            continue
                        }
                    }
                    let recordID = UUID().uuidString.prefix(12).lowercased()
                    if let path = display.screenshotPath {
                        let destPath = store.screenshotsDir + "\(recordID).png"
                        try? FileManager.default.copyItem(atPath: path, toPath: destPath)
                    }
                    // Run app context hook if available
                    let hookContext: String? = if display.isFocused {
                        runAppContextHook(
                            dataDir: config.dataDir,
                            appName: display.appName ?? "Unknown",
                            windowTitle: display.windowTitle ?? "",
                            pid: display.pid
                        )
                    } else {
                        nil
                    }

                    records.append(ScreenshotRecord(
                        id: String(recordID),
                        unixTimeMs: nowMs,
                        url: normalizeURL(display.url),
                        app: display.appName ?? "Unknown",
                        title: display.windowTitle,
                        isFocused: display.isFocused,
                        isPlayingMedia: display.isPlayingMedia,
                        appContext: hookContext
                    ))
                }

                // Transcription records
                for segment in segments {
                    records.append(TranscriptionRecord(
                        unixTimeMs: segment.unixTimeMs,
                        text: segment.text
                    ))
                }

                // Camera records
                if let camCapture {
                    let cameraImages = await camCapture.captureAll()
                    for cam in cameraImages {
                        let recordID = UUID().uuidString.prefix(12).lowercased()
                        let destPath = store.camerasDir + "\(recordID).png"
                        if let dest = CGImageDestinationCreateWithURL(
                            URL(fileURLWithPath: destPath) as CFURL, "public.png" as CFString, 1, nil
                        ) {
                            CGImageDestinationAddImage(dest, cam.image, nil)
                            if CGImageDestinationFinalize(dest) {
                                records.append(CameraRecord(
                                    id: String(recordID),
                                    unixTimeMs: nowMs
                                ))
                            }
                        }
                    }
                }

                // Write to store
                if !records.isEmpty {
                    do {
                        try store.writeCapture(records: records, timestamp: now)
                        let screenshotCount = records.filter { $0 is ScreenshotRecord }.count
                        let transcriptionCount = records.filter { $0 is TranscriptionRecord }.count
                        let cameraCount = records.filter { $0 is CameraRecord }.count
                        NSLog("[chronixd-capture] Wrote %d records (screenshots: %d, transcriptions: %d, cameras: %d)",
                              records.count, screenshotCount, transcriptionCount, cameraCount)
                    } catch {
                        NSLog("[chronixd-capture] Write failed: %@", "\(error)")
                    }
                }
            }
        }
    }

    func stop() {
        captureTimerTask?.cancel()
        consumeTask?.cancel()
        mediaCheckTask?.cancel()
        micCapture?.stop()
        cameraCapture?.stop()
        updateState(.stopped)
    }

    private func updateState(_ newState: State) {
        lock.lock()
        state = newState
        lock.unlock()
        onStateChange?(newState)
    }
}

// MARK: - TranscriptionSegment

struct TranscriptionSegment: Sendable {
    let unixTimeMs: Int64
    let text: String
}

// MARK: - TranscriptionBuffer

final class TranscriptionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [TranscriptionSegment] = []

    func append(_ segment: TranscriptionSegment) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
    }

    func flush() -> [TranscriptionSegment] {
        lock.lock()
        let result = segments
        segments.removeAll()
        lock.unlock()
        return result
    }
}

// MARK: - DedupKey

struct DedupKey: Equatable {
    let app: String
    let title: String
    let url: String
}

// MARK: - DedupState

final class DedupState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastKeys: [CGDirectDisplayID: DedupKey] = [:]

    func isDuplicate(displayID: CGDirectDisplayID, key: DedupKey) -> Bool {
        lock.lock()
        defer {
            lastKeys[displayID] = key
            lock.unlock()
        }
        return lastKeys[displayID] == key
    }
}

// MARK: - App Context Hooks

/// Run a hook script at `{dataDir}/hooks/{appName}` if it exists and is executable.
/// Arguments: $1 = windowTitle, $2 = pid. Timeout: 2 seconds.
func runAppContextHook(dataDir: String, appName: String, windowTitle: String, pid: Int32) -> String? {
    let hookPath = (dataDir as NSString).appendingPathComponent("hooks/\(appName)")
    guard FileManager.default.isExecutableFile(atPath: hookPath) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: hookPath)
    process.arguments = [windowTitle, String(pid)]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        NSLog("[chronixd-capture] Hook failed to launch for %@: %@", appName, "\(error)")
        return nil
    }

    // Timeout after 2 seconds
    let deadline = DispatchTime.now() + .seconds(2)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        NSLog("[chronixd-capture] Hook timed out for %@", appName)
        return nil
    }

    guard process.terminationStatus == 0 else {
        NSLog("[chronixd-capture] Hook exited with status %d for %@", process.terminationStatus, appName)
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == true ? nil : output
}

// MARK: - Helpers

func normalizeURL(_ url: String?) -> String? {
    guard let url, !url.isEmpty else { return nil }
    if url.contains("://") { return url }
    return "https://" + url
}

// MARK: - CaptureManagerError

enum CaptureManagerError: Swift.Error, LocalizedError {
    case speechNotAvailable
    case accessibilityPermissionDenied
    case screenRecordingPermissionDenied
    case cameraPermissionDenied
    case unsupportedLocale
    case noCompatibleAudioFormat
    case noDataDir

    var errorDescription: String? {
        switch self {
        case .speechNotAvailable:
            "Speech recognition is not available."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required. Grant it in System Settings > Privacy & Security > Accessibility."
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is required. Grant it in System Settings > Privacy & Security > Screen Recording."
        case .cameraPermissionDenied:
            "Camera permission is required. Grant it in System Settings > Privacy & Security > Camera."
        case .unsupportedLocale:
            "The specified locale is not supported for speech recognition."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        case .noDataDir:
            "No data directory configured. Set CHRONIXD_CAPTURE_DATA_DIR environment variable or pass --data-dir."
        }
    }
}
