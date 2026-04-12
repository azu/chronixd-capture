import ApplicationServices
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Noora
import ScreenCaptureKit
import Speech

private nonisolated(unsafe) var captureSignalWriteFD: Int32 = -1

// MARK: - Capture

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture transcription and screen context periodically to disk."
    )

    @Option(
        name: .long,
        help: "Persistent data directory (required)."
    ) var dataDir: String

    @Option(
        name: .long,
        help: "Capture interval in seconds (default: 30, minimum: 5)."
    ) var interval: Int = 30

    @Option(
        name: .long,
        help: "Camera device ID to capture. Can be specified multiple times."
    ) var camera: [String] = []

    @Option(
        name: .long,
        help: "App names to ignore (comma-separated). Displays with these apps are skipped.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreApps: [String]?

    @Option(
        name: .long,
        help: "Title patterns to ignore (comma-separated). Displays with matching window titles are skipped.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreTitles: [String]?

    @Option(
        name: .long,
        help: "URL patterns to ignore (comma-separated). Displays with matching URLs are skipped.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreUrls: [String]?

    @Flag(
        name: .long,
        help: "Disable deduplication."
    ) var noDedup: Bool = false

    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    func validate() throws {
        guard interval >= 5 else {
            throw ValidationError("--interval must be at least 5 seconds.")
        }
    }

    @MainActor mutating func run() async throws {
        let captureInterval = interval

        // Permission checks
        guard SpeechTranscriber.isAvailable else {
            throw CaptureError.speechTranscriberNotAvailable
        }

        // Microphone permission (checked by trying to start audio engine)
        // Accessibility permission
        guard AXIsProcessTrusted() else {
            throw CaptureError.accessibilityPermissionDenied
        }

        // Screen recording permission
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenRecordingPermissionDenied
        }

        // Camera permission if needed
        if !camera.isEmpty {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw CameraCaptureError.permissionDenied
            }
        }

        // Locale check
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw CaptureError.unsupportedLocale
        }

        for loc in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: loc)
        }
        try await AssetInventory.reserve(locale: locale)

        // Set up transcriber
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]

        // Download assets if needed
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            let piped = isatty(STDOUT_FILENO) == 0
            struct DevNull: StandardPipelining { func write(content _: String) {} }
            let noora = if piped {
                Noora(standardPipelines: .init(output: DevNull()))
            } else {
                Noora()
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await noora.progressBarStep(
                    message: "Downloading required assets…"
                ) { @Sendable progressCallback in
                    struct ReportProgress: @unchecked Sendable {
                        let callAsFunction: (Double) -> Void
                    }
                    let reportProgress = ReportProgress(callAsFunction: progressCallback)
                    try await withThrowingDiscardingTaskGroup { group in
                        group.addTask {
                            while !Task.isCancelled, !request.progress.isFinished {
                                reportProgress.callAsFunction(request.progress.fractionCompleted)
                                try await Task.sleep(for: .seconds(0.1))
                            }
                        }
                        try await request.downloadAndInstall()
                        group.cancelAll()
                    }
                }
            }
        }

        let analyzer = SpeechAnalyzer(modules: modules)

        // Set up streaming input
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw CaptureError.noCompatibleAudioFormat
        }

        let capture = try MicrophoneCapture(
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )
        try capture.start()
        try await analyzer.start(inputSequence: inputSequence)

        // Set up CaptureStore
        let store = CaptureStore(dataDir: dataDir)
        try store.setup()

        // Set up camera capture
        let cameraCapture: CameraCapture? = if !camera.isEmpty {
            try CameraCapture(deviceIDs: camera)
        } else {
            nil
        }

        // Set up signal handling
        var signalPipe: [Int32] = [0, 0]
        pipe(&signalPipe)
        let signalReadFD = signalPipe[0]
        captureSignalWriteFD = signalPipe[1]

        // Suppress ^C echo
        var originalTermios = termios()
        let hasTerminal = isatty(STDIN_FILENO) != 0
        if hasTerminal {
            tcgetattr(STDIN_FILENO, &originalTermios)
            var raw = originalTermios
            raw.c_lflag &= ~UInt(ECHOCTL)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }

        signal(SIGINT) { _ in
            _ = write(captureSignalWriteFD, "x", 1)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Capturing… Press Ctrl+C to stop.\n".utf8))
        }

        // Thread-safe transcription buffer
        let transcriptionBuffer = TranscriptionBuffer()

        // Screen context capture
        let screenCapture = ScreenContextCapture()

        // Dedup state
        let dedupEnabled = !noDedup
        let dedupState = DedupState()

        // Copy ignore filters to local vars for closure capture
        let ignoreAppPatterns = ignoreApps
        let ignoreTitlePatterns = ignoreTitles
        let ignoreUrlPatterns = ignoreUrls

        // Background task: poll media playback state every 2 seconds
        // Mutes mic when media is actively playing (NowPlaying playbackRate > 0)
        let muteCaptureRef = capture
        let mediaCheckTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let shouldMute = await AudioOutputDetector.isMediaPlaying()
                if muteCaptureRef.isMuted != shouldMute {
                    muteCaptureRef.isMuted = shouldMute
                    if isatty(STDERR_FILENO) != 0 {
                        let msg = shouldMute
                            ? "[capture] Media playing, muting mic"
                            : "[capture] Media stopped, unmuting mic"
                        FileHandle.standardError.write(Data("\(msg)\n".utf8))
                    }
                }
            }
        }

        // Background task 1: consume transcriber results into buffer
        let consumeTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let timeMs = Int64(Date().timeIntervalSince1970 * 1000)
                    transcriptionBuffer.append(TranscriptionSegment(unixTimeMs: timeMs, text: text))
                }
            } catch {
                // Transcriber ended (e.g. after finalize)
            }
        }

        // Background task 2: periodic capture timer
        let intervalSeconds = captureInterval
        let captureStore = store
        let hooksDataDir = dataDir
        let captureTimerTask = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                let now = Date()
                let nowMs = Int64(now.timeIntervalSince1970 * 1000)

                // Capture screen context
                let screenContext: ScreenContext
                do {
                    screenContext = try await screenCapture.capture()
                } catch {
                    if isatty(STDERR_FILENO) != 0 {
                        FileHandle.standardError.write(Data("[capture] Screen capture failed: \(error)\n".utf8))
                    }
                    continue
                }

                // Flush transcription buffer
                let segments = transcriptionBuffer.flush()

                // Build records
                var records: [any CaptureRecord] = []

                // Screenshot records for each display (skip ignored + per-display dedup)
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
                        let destPath = captureStore.screenshotsDir + "\(recordID).png"
                        try? FileManager.default.copyItem(atPath: path, toPath: destPath)
                    }
                    let hookContext: String? = if display.isFocused {
                        runAppContextHook(
                            dataDir: hooksDataDir,
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
                        appContext: hookContext,
                        idleSeconds: display.idleSeconds.map { ($0 * 10).rounded() / 10 },
                        scrollPosition: display.scrollPosition.map { ($0 * 1000).rounded() / 1000 }
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
                if let cameraCapture {
                    let cameraImages = await cameraCapture.captureAll()
                    for cam in cameraImages {
                        let recordID = UUID().uuidString.prefix(12).lowercased()
                        let destPath = captureStore.camerasDir + "\(recordID).png"
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
                        try captureStore.writeCapture(records: records, timestamp: now)
                        if isatty(STDERR_FILENO) != 0 {
                            let screenshotCount = records.filter { $0 is ScreenshotRecord }.count
                            let transcriptionCount = records.filter { $0 is TranscriptionRecord }.count
                            let cameraCount = records.filter { $0 is CameraRecord }.count
                            FileHandle.standardError.write(Data(
                                "[capture] Wrote \(records.count) records (screenshots: \(screenshotCount), transcriptions: \(transcriptionCount), cameras: \(cameraCount))\n".utf8
                            ))
                        }
                    } catch {
                        if isatty(STDERR_FILENO) != 0 {
                            FileHandle.standardError.write(Data("[capture] Write failed: \(error)\n".utf8))
                        }
                    }
                }
            }
        }

        // Wait for SIGINT in background, then gracefully shut down
        nonisolated(unsafe) var savedTermios = originalTermios
        let restoreTerminal = hasTerminal
        let (shutdownStream, shutdownContinuation) = AsyncStream.makeStream(of: Void.self)
        Task.detached {
            var buf: UInt8 = 0
            _ = read(signalReadFD, &buf, 1)
            close(signalReadFD)
            close(captureSignalWriteFD)
            if restoreTerminal {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            }
            capture.stop()
            cameraCapture?.stop()
            if !capture.isMuted {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            captureTimerTask.cancel()
            consumeTask.cancel()
            mediaCheckTask.cancel()
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("\nCapture stopped.\n".utf8))
            }
            shutdownContinuation.yield()
            shutdownContinuation.finish()
        }

        // Block until shutdown signal
        for await _ in shutdownStream {
            break
        }
    }
}

// MARK: - TranscriptionSegment

private struct TranscriptionSegment: Sendable {
    let unixTimeMs: Int64
    let text: String
}

// MARK: - TranscriptionBuffer

private final class TranscriptionBuffer: @unchecked Sendable {
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

private struct DedupKey: Equatable {
    let app: String
    let title: String
    let url: String
}

// MARK: - DedupState

private final class DedupState: @unchecked Sendable {
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
        return nil
    }

    let deadline = DispatchTime.now() + .seconds(2)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }

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
