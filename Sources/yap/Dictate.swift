import ApplicationServices
import ArgumentParser
@preconcurrency import AVFoundation
import FoundationModels
@preconcurrency import Noora
import ScreenCaptureKit
import Speech

private nonisolated(unsafe) var dictateSignalWriteFD: Int32 = -1

// MARK: - CorrectorBackend

enum CorrectorBackend: String, ExpressibleByArgument, Sendable {
    case local
    case claude
    case mlx
}

// MARK: - Corrector Protocol

enum CorrectionStatus: Sendable {
    case corrected
    case unchanged
    case timeout
    case error(String)
}

struct CorrectionResult: Sendable {
    let original: String
    let corrected: String
    let status: CorrectionStatus
}

protocol Corrector: Sendable {
    func correct(text: String, context: ScreenContext) async -> CorrectionResult
}

// MARK: - Dictate

struct Dictate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe live microphone input in real time."
    )

    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    @Flag(
        help: "Replaces certain words and phrases with a redacted form."
    ) var censor: Bool = false

    @Flag(
        help: "Output format for the transcription."
    ) var outputFormat: OutputFormat = .txt

    @Option(
        name: .shortAndLong,
        help: "Maximum sentence length in characters for timed output formats."
    ) var maxLength: Int = 40

    @Flag(
        help: "Include word-level timestamps in JSON output."
    ) var wordTimestamps: Bool = false

    @Option(
        name: .long,
        help: "Use screen context to improve transcription accuracy. Values: local (on-device LLM), claude (claude CLI), mlx (MLX VLM)."
    ) var contextAware: CorrectorBackend? = nil

    @Flag(
        name: .long,
        help: "Print captured screen context to stdout for debugging (requires --context-aware)."
    ) var debug: Bool = false

    @Option(
        name: .long,
        help: "Model to use for claude backend (e.g. haiku, sonnet, opus). Default: haiku."
    ) var claudeModel: String = "haiku"

    @Option(
        name: .long,
        help: "MLX model ID from Hugging Face (e.g. mlx-community/Qwen2.5-VL-3B-Instruct-4bit)."
    ) var mlxModel: String?

    @Option(
        name: .long,
        help: "Comma-separated keywords to detect media/video sites in window titles. Matched displays are flagged as playing media.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreTitles: [String]?

    @Option(
        name: .long,
        help: "Camera device ID to capture. Use 'yap cameras' to list available devices. Can be specified multiple times."
    ) var camera: [String] = []

    @Option(
        name: .long,
        help: "Minimum text length (in characters) to trigger LLM correction. Shorter texts are output as-is. Default: 5."
    ) var minCorrectionLength: Int = 5

    @Option(
        name: .long,
        help: "Context explanation backend (runs in parallel with correction). Values: claude, mlx."
    ) var contextExplain: CorrectorBackend? = nil

    @Option(
        name: .long,
        help: "Minimum interval (seconds) between context explanations. 0 = every correction. Default: 0."
    ) var contextExplainInterval: TimeInterval = 0

    @MainActor mutating func run() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw Transcribe.Error.speechTranscriberNotAvailable
        }

        if let backend = contextAware {
            if backend == .local {
                guard SystemLanguageModel.default.availability == .available else {
                    throw DictateError.languageModelNotAvailable
                }
            }
            guard AXIsProcessTrusted() else {
                throw DictateError.accessibilityPermissionDenied
            }
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw DictateError.screenRecordingPermissionDenied
            }
            if !camera.isEmpty {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard granted else {
                    throw CameraCaptureError.permissionDenied
                }
            }
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw Transcribe.Error.unsupportedLocale
        }

        for locale in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: locale)
        }
        try await AssetInventory.reserve(locale: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censor ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: (outputFormat.needsAudioTimeRange || contextAware != nil) ? [.audioTimeRange] : []
        )
        let modules: [any SpeechModule] = [transcriber]

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

        // Get target audio format from the analyzer
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw DictateError.noCompatibleAudioFormat
        }

        // Set up AVAudioEngine for microphone capture
        let capture = try MicrophoneCapture(
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )
        try capture.start()

        // Start the analyzer with streaming input
        try await analyzer.start(inputSequence: inputSequence)

        // Set up graceful shutdown
        var signalPipe: [Int32] = [0, 0]
        pipe(&signalPipe)
        let signalReadFD = signalPipe[0]
        dictateSignalWriteFD = signalPipe[1]

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
            _ = write(dictateSignalWriteFD, "x", 1)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Dictating… Press Ctrl+C to stop.\n".utf8))
        }

        let cameraCapture: CameraCapture? = if !camera.isEmpty {
            try CameraCapture(deviceIDs: camera)
        } else {
            nil
        }

        // Wait for SIGINT in background, then gracefully shut down
        nonisolated(unsafe) var savedTermios = originalTermios
        let restoreTerminal = hasTerminal
        Task.detached {
            var buf: UInt8 = 0
            _ = read(signalReadFD, &buf, 1)
            close(signalReadFD)
            close(dictateSignalWriteFD)
            if restoreTerminal {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            }
            capture.stop()
            cameraCapture?.stop()
            if !capture.isMuted {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }

        // Stream results as they arrive
        let format = outputFormat
        let sentenceMaxLength = maxLength
        let backend = contextAware
        let showDebug = debug
        let minCorrLength = minCorrectionLength

        if let backend {
            let screenCapture = if let ignoreTitles {
                ScreenContextCapture(mediaTitleKeywords: ignoreTitles)
            } else {
                ScreenContextCapture()
            }
            let corrector: any Corrector = switch backend {
            case .local: TranscriptionCorrector()
            case .claude: ClaudeCorrector(model: claudeModel)
            case .mlx: MLXCorrector(modelID: mlxModel)
            }
            let useScreenshots = backend == .claude || backend == .mlx

            // Pre-load MLX model at startup
            if let mlxCorrector = corrector as? MLXCorrector {
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("Loading MLX model…\n".utf8))
                }
                try await mlxCorrector.loadModelIfNeeded()
            }

            // Context explainer (runs in parallel with correction)
            let explainer: (any ContextExplainer)? = if let explainBackend = contextExplain {
                switch explainBackend {
                case .claude: ClaudeContextExplainer(model: claudeModel) as any ContextExplainer
                case .mlx: MLXContextExplainer(modelID: mlxModel) as any ContextExplainer
                case .local: nil as (any ContextExplainer)?
                }
            } else {
                nil as (any ContextExplainer)?
            }
            if let mlxExplainer = explainer as? MLXContextExplainer {
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("Loading MLX explainer model…\n".utf8))
                }
                try await mlxExplainer.loadModelIfNeeded()
            }
            let explainInterval = contextExplainInterval

            let emptyContext = ScreenContext(
                displays: [], cameras: [], timestamp: Date()
            )

            // Timestamp of last unmute — results before this are stale (from pre-mute buffer)
            nonisolated(unsafe) var lastUnmuteTime = Date.distantPast

            // Background task: poll media playback state every 2 seconds
            // Mutes mic when any media is actively playing (NowPlaying playbackRate > 0)
            let muteCaptureRef = capture
            let mediaCheckDebug = showDebug
            let mediaCheckTask = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let shouldMute = await AudioOutputDetector.isMediaPlaying()
                    if muteCaptureRef.isMuted != shouldMute {
                        muteCaptureRef.isMuted = shouldMute
                        if !shouldMute {
                            // Record unmute time — discard results that arrived before this
                            lastUnmuteTime = Date()
                        }
                        if mediaCheckDebug {
                            let msg = shouldMute
                                ? "[context-aware] Media playing, muting mic"
                                : "[context-aware] Media stopped, unmuting mic"
                            print(msg)
                            fflush(stdout)
                        }
                    }
                }
            }

            // Background context capture: pre-capture screen + camera every 2 seconds
            // so the context is already available when a transcription result arrives.
            final class ContextCache: @unchecked Sendable {
                private let lock = NSLock()
                private var _context: ScreenContext
                init(_ context: ScreenContext) { _context = context }
                var context: ScreenContext {
                    get { lock.lock(); defer { lock.unlock() }; return _context }
                    set { lock.lock(); _context = newValue; lock.unlock() }
                }
            }
            let contextCache = ContextCache(emptyContext)
            // Capture screen on speech start (VAD trigger) with 1.5s throttle
            let (speechStream, speechContinuation) = AsyncStream.makeStream(of: Void.self)
            capture.onSpeechStart = {
                speechContinuation.yield()
            }
            let contextCaptureTask = Task { @MainActor in
                var lastCaptureTime = Date.distantPast
                for await _ in speechStream {
                    let now = Date()
                    guard now.timeIntervalSince(lastCaptureTime) > 1.5 else { continue }
                    lastCaptureTime = now
                    let captureStart = ContinuousClock.now
                    let captured: ScreenContext
                    if useScreenshots {
                        captured = (try? await screenCapture.captureWithScreenshots()) ?? emptyContext
                    } else {
                        captured = (try? await screenCapture.capture()) ?? emptyContext
                    }
                    contextCache.context = captured
                    if showDebug {
                        let elapsed = ContinuousClock.now - captureStart
                        print("[context-aware] Speech-triggered screen capture took \(elapsed)")
                        fflush(stdout)
                        logScreenContext(captured)
                    }
                }
            }

            if format == .txt {
                for try await result in transcriber.results {
                    let now = Date()
                    let screenContext = contextCache.context

                    // Discard stale results from before unmute (pre-mute audio buffer)
                    if now < lastUnmuteTime {
                        if showDebug {
                            print("[context-aware] Discarding stale result (pre-mute buffer)")
                            fflush(stdout)
                        }
                        continue
                    }

                    if showDebug {
                        print("[context-aware] Mic muted: \(capture.isMuted)")
                        fflush(stdout)
                    }

                    for chunk in result.text.splitAtTimeGaps(threshold: 1.5) {
                        let text = String(chunk.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        if showDebug {
                            print("[context-aware] Raw: \(text)")
                            fflush(stdout)
                        }
                        // Skip LLM correction for short texts
                        if text.count < minCorrLength {
                            if showDebug {
                                print("[context-aware] Too short (\(text.count) chars), skipping correction")
                                fflush(stdout)
                            }
                            print(text)
                            fflush(stdout)
                            continue
                        }
                        // Camera capture on demand (only at correction time)
                        var correctionContext = screenContext
                        if let cameraCapture = cameraCapture {
                            let cameraImages = await cameraCapture.captureAll()
                            let dir: String
                            if let screenshotPath = correctionContext.displays.first?.screenshotPath {
                                dir = URL(fileURLWithPath: screenshotPath).deletingLastPathComponent().path
                            } else {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "yyyyMMdd-HHmmss"
                                dir = NSTemporaryDirectory() + "yap/" + formatter.string(from: Date())
                                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                            }
                            var cameraContexts: [CameraContext] = []
                            for (index, cam) in cameraImages.enumerated() {
                                let path = dir + "/camera-\(index).png"
                                if let dest = CGImageDestinationCreateWithURL(
                                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
                                ) {
                                    let scale = min(1.0, 1280.0 / Double(cam.image.width))
                                    let newWidth = Int(Double(cam.image.width) * scale)
                                    let newHeight = Int(Double(cam.image.height) * scale)
                                    let colorSpace = cam.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                                    if let ctx = CGContext(
                                        data: nil, width: newWidth, height: newHeight,
                                        bitsPerComponent: cam.image.bitsPerComponent,
                                        bytesPerRow: 0, space: colorSpace,
                                        bitmapInfo: cam.image.alphaInfo.rawValue
                                    ) {
                                        ctx.interpolationQuality = .high
                                        ctx.draw(cam.image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
                                        if let resized = ctx.makeImage() {
                                            CGImageDestinationAddImage(dest, resized, nil)
                                        } else {
                                            CGImageDestinationAddImage(dest, cam.image, nil)
                                        }
                                    } else {
                                        CGImageDestinationAddImage(dest, cam.image, nil)
                                    }
                                    if CGImageDestinationFinalize(dest) {
                                        cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: path))
                                    } else {
                                        cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: nil))
                                    }
                                }
                            }
                            correctionContext = ScreenContext(
                                displays: correctionContext.displays,
                                cameras: cameraContexts,
                                timestamp: correctionContext.timestamp
                            )
                        }
                        let correctionStart = ContinuousClock.now
                        let correction = await corrector.correct(text: text, context: correctionContext)
                        if showDebug {
                            let elapsed = ContinuousClock.now - correctionStart
                            print("[context-aware] Correction took \(elapsed)")
                            fflush(stdout)
                        }
                        if showDebug {
                            let images = screenContext.displays.filter { $0.screenshotPath != nil }.count
                            switch correction.status {
                            case .corrected:
                                print("[context-aware] Corrected (images: \(images))")
                            case .unchanged:
                                print("[context-aware] No correction needed (images: \(images))")
                            case .timeout:
                                print("[context-aware] Correction timed out")
                            case .error(let msg):
                                print("[context-aware] Correction error: \(msg)")
                            }
                            fflush(stdout)
                        }
                        print(correction.corrected)
                        fflush(stdout)
                        // Parallel context explanation
                        if let explainer {
                            let ctx = correctionContext
                            nonisolated(unsafe) var lastExplainTime = Date.distantPast
                            let interval = explainInterval
                            Task.detached {
                                let now = Date()
                                guard now.timeIntervalSince(lastExplainTime) >= interval else { return }
                                lastExplainTime = now
                                if let explanation = await explainer.explain(context: ctx) {
                                    if format == .ndjson {
                                        print(OutputFormat.formatContextExplanation(activity: explanation.activity, summary: explanation.summary))
                                    } else {
                                        print("activity: \(explanation.activity) / summary: \(explanation.summary)")
                                    }
                                    fflush(stdout)
                                }
                            }
                        }
                    }
                }
                mediaCheckTask.cancel()
            contextCaptureTask.cancel()
            } else {
                if let header = format.header(locale: locale) {
                    print(header)
                }
                let includeWords = wordTimestamps
                var segmentIndex = 0

                for try await result in transcriber.results {
                    let currentContext = contextCache.context

                    // Skip output when media site is visible AND media is actively playing
                    let hasMediaSite = currentContext.displays.contains { $0.isPlayingMedia }
                    if hasMediaSite, await AudioOutputDetector.isMediaPlaying() {
                        if showDebug {
                            print("[context-aware] Media playing, skipping output")
                            fflush(stdout)
                        }
                        continue
                    }

                    for chunk in result.text.splitAtTimeGaps(threshold: 1.5) {
                        let allWords = includeWords ? chunk.wordTimestamps() : nil
                        for sentence in chunk.sentences(maxLength: sentenceMaxLength) {
                            guard let timeRange = sentence.audioTimeRange else { continue }
                            let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let words = allWords?.filter {
                                $0.timeRange.start.seconds >= timeRange.start.seconds
                                    && $0.timeRange.end.seconds <= timeRange.end.seconds
                            }
                            if showDebug {
                                print("[context-aware] Raw: \(text)")
                                fflush(stdout)
                            }
                            // Skip LLM correction for short texts
                            let correction: CorrectionResult
                            if text.count < minCorrLength {
                                if showDebug {
                                    print("[context-aware] Too short (\(text.count) chars), skipping correction")
                                    fflush(stdout)
                                }
                                correction = CorrectionResult(original: text, corrected: text, status: .unchanged)
                            } else {
                                // Camera capture on demand
                                var correctionContext = currentContext
                                if let cameraCapture = cameraCapture {
                                    let cameraImages = await cameraCapture.captureAll()
                                    let dir = correctionContext.displays.first?.screenshotPath
                                        .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
                                        ?? NSTemporaryDirectory() + "yap/"
                                    var cameraContexts: [CameraContext] = []
                                    for (index, cam) in cameraImages.enumerated() {
                                        let path = dir + "/camera-\(index).png"
                                        if let dest = CGImageDestinationCreateWithURL(
                                            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
                                        ) {
                                            let scale = min(1.0, 1280.0 / Double(cam.image.width))
                                            let newWidth = Int(Double(cam.image.width) * scale)
                                            let newHeight = Int(Double(cam.image.height) * scale)
                                            let colorSpace = cam.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                                            if let ctx = CGContext(
                                                data: nil, width: newWidth, height: newHeight,
                                                bitsPerComponent: cam.image.bitsPerComponent,
                                                bytesPerRow: 0, space: colorSpace,
                                                bitmapInfo: cam.image.alphaInfo.rawValue
                                            ) {
                                                ctx.interpolationQuality = .high
                                                ctx.draw(cam.image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
                                                if let resized = ctx.makeImage() {
                                                    CGImageDestinationAddImage(dest, resized, nil)
                                                } else {
                                                    CGImageDestinationAddImage(dest, cam.image, nil)
                                                }
                                            } else {
                                                CGImageDestinationAddImage(dest, cam.image, nil)
                                            }
                                            if CGImageDestinationFinalize(dest) {
                                                cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: path))
                                            } else {
                                                cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: nil))
                                            }
                                        }
                                    }
                                    correctionContext = ScreenContext(
                                        displays: correctionContext.displays,
                                        cameras: cameraContexts,
                                        timestamp: correctionContext.timestamp
                                    )
                                }
                                let correctionStart = ContinuousClock.now
                                correction = await corrector.correct(text: text, context: correctionContext)
                                if showDebug {
                                    let elapsed = ContinuousClock.now - correctionStart
                                    print("[context-aware] Correction took \(elapsed)")
                                    fflush(stdout)
                                }
                            }
                            if segmentIndex > 0, let sep = format.segmentSeparator {
                                print(sep, terminator: "")
                            }
                            segmentIndex += 1
                            print(format.formatCorrectedSegment(
                                index: segmentIndex,
                                timeRange: timeRange,
                                original: correction.original,
                                corrected: correction.corrected,
                                words: words
                            ), terminator: "")
                            fflush(stdout)
                            // Parallel context explanation
                            if let explainer {
                                let ctx = currentContext
                                Task.detached {
                                    if let explanation = await explainer.explain(context: ctx) {
                                        if format == .ndjson {
                                            print(OutputFormat.formatContextExplanation(activity: explanation.activity, summary: explanation.summary))
                                        } else {
                                            print("activity: \(explanation.activity) / summary: \(explanation.summary)")
                                        }
                                        fflush(stdout)
                                    }
                                }
                            }
                        }
                    }
                }
                if segmentIndex > 0 { print() }
                if let footer = format.footer {
                    print(footer)
                }
            }
            mediaCheckTask.cancel()
            contextCaptureTask.cancel()
        } else if format == .txt {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print(text, terminator: "")
                    fflush(stdout)
                }
            }
            print()
        } else {
            if let header = format.header(locale: locale) {
                print(header)
            }
            let includeWords = wordTimestamps
            var segmentIndex = 0
            for try await result in transcriber.results {
                for chunk in result.text.splitAtTimeGaps(threshold: 1.5) {
                    let allWords = includeWords ? chunk.wordTimestamps() : nil
                    for sentence in chunk.sentences(maxLength: sentenceMaxLength) {
                        guard let timeRange = sentence.audioTimeRange else { continue }
                        let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let words = allWords?.filter {
                            $0.timeRange.start.seconds >= timeRange.start.seconds
                                && $0.timeRange.end.seconds <= timeRange.end.seconds
                        }
                        if segmentIndex > 0, let sep = format.segmentSeparator {
                            print(sep, terminator: "")
                        }
                        segmentIndex += 1
                        print(format.formatSegment(index: segmentIndex, timeRange: timeRange, text: text, words: words), terminator: "")
                        fflush(stdout)
                    }
                }
            }
            if segmentIndex > 0 { print() }
            if let footer = format.footer {
                print(footer)
            }
        }
    }
}

// MARK: - Debug Helpers

private func logScreenContext(_ context: ScreenContext) {
    var lines: [String] = ["[context-aware] Screen context captured:"]
    for (i, display) in context.displays.enumerated() {
        lines.append("  Display \(i + 1) (ID: \(display.displayID)):")
        if let appName = display.appName {
            lines.append("    App: \(appName)")
        }
        if let windowTitle = display.windowTitle {
            lines.append("    Window: \(windowTitle)")
        }
        if let url = display.url {
            lines.append("    URL: \(url)")
        }
        if let path = display.screenshotPath {
            lines.append("    Screenshot: \(path)")
        }
        if display.isPlayingMedia {
            lines.append("    Media site detected")
        }
        if !display.ocrText.isEmpty {
            lines.append("    OCR: \(display.ocrText.count) chars")
        }
    }
    for (i, camera) in context.cameras.enumerated() {
        lines.append("  Camera \(i + 1) (ID: \(camera.deviceID)):")
        if let path = camera.imagePath {
            lines.append("    Photo: \(path)")
        }
    }
    let focusedDisplays = context.displays.filter { $0.isFocused }
    if let focused = focusedDisplays.first {
        lines.append("  Focused: Display \(focused.displayID)")
    }
    let message = lines.joined(separator: "\n")
    print(message)
    fflush(stdout)
}

// MARK: - MicrophoneCapture

final class MicrophoneCapture: @unchecked Sendable {
    // MARK: Lifecycle

    init(targetFormat: AVAudioFormat, inputContinuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.targetFormat = targetFormat
        self.inputContinuation = inputContinuation
        audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw DictateError.microphonePermissionDenied
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw DictateError.noCompatibleAudioFormat
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [self] buffer, _ in
            handleBuffer(buffer)
        }
    }

    // MARK: Internal

    let audioEngine: AVAudioEngine
    let converter: AVAudioConverter
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    let targetFormat: AVAudioFormat

    /// When true, audio buffers are discarded (not sent to speech recognizer).
    nonisolated(unsafe) var isMuted: Bool = false

    /// Called when voice activity starts (silence → speech transition).
    nonisolated(unsafe) var onSpeechStart: (() -> Void)?
    /// RMS threshold for voice activity detection.
    private let vadThreshold: Float = 0.01
    /// Silence duration (seconds) needed to consider speech ended.
    private let silenceDuration: TimeInterval = 0.3
    /// Whether currently in a speech segment.
    nonisolated(unsafe) private var inSpeech: Bool = false
    /// Timestamp when silence started.
    nonisolated(unsafe) private var silenceStartTime: Date?

    func stop() {
        audioEngine.stop()
        inputContinuation.finish()
    }

    func start() throws {
        do {
            try audioEngine.start()
        } catch {
            throw DictateError.microphonePermissionDenied
        }
    }

    // MARK: Private

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted else {
            inSpeech = false
            silenceStartTime = nil
            return
        }
        // Voice Activity Detection: detect silence → speech transition
        // Only triggers once per speech segment (requires sustained silence to reset)
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(frames, 1)))
            if rms > vadThreshold {
                silenceStartTime = nil
                if !inSpeech {
                    inSpeech = true
                    onSpeechStart?()
                }
            } else {
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                } else if let start = silenceStartTime, Date().timeIntervalSince(start) >= silenceDuration {
                    inSpeech = false
                }
            }
        }
        let frameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / converter.inputFormat.sampleRate)
        )
        guard frameCapacity > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let sourceBuffer = buffer
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if error == nil, convertedBuffer.frameLength > 0 {
            inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
        }
    }
}

// MARK: - DictateError

enum DictateError: Swift.Error, LocalizedError {
    case microphonePermissionDenied
    case noCompatibleAudioFormat
    case languageModelNotAvailable
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone, then restart the terminal."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        case .languageModelNotAvailable:
            "On-device language model is not available. Ensure Apple Intelligence is enabled in System Settings."
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is required for --context-aware. Grant it in System Settings > Privacy & Security > Screen Recording."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required for --context-aware. Grant it in System Settings > Privacy & Security > Accessibility."
        }
    }
}
