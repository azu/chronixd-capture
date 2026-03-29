import ArgumentParser
import Foundation

struct Context: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Query captured context data by time range."
    )

    @Option(name: .long, help: "Data directory (required).")
    var dataDir: String?

    @Option(name: .long, help: "Start time (ISO 8601 or HH:mm for today).")
    var from: String?

    @Option(name: .long, help: "End time (ISO 8601 or HH:mm for today). Defaults to now.")
    var to: String?

    @Option(name: .long, help: "Duration like 30m, 1h, 2h30m, or seconds.")
    var last: String?

    @Flag(name: .long, help: "Output all record types with full fields.")
    var detail: Bool = false

    @Flag(name: .long, help: "Print the output schema for AI consumption.")
    var schema: Bool = false

    func validate() throws {
        if schema { return }
        guard dataDir != nil else {
            throw ValidationError("--data-dir is required.")
        }
        if last != nil && from != nil {
            throw ValidationError("--last and --from are mutually exclusive.")
        }
        if last == nil && from == nil {
            throw ValidationError("Specify either --last or --from.")
        }
    }

    func run() throws {
        if schema {
            print(Self.schemaText)
            return
        }

        guard let dataDir else { return }

        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let endMs: Int64
        if let toStr = to {
            endMs = try Self.parseTime(toStr)
        } else {
            endMs = nowMs
        }

        let startMs: Int64
        if let lastStr = last {
            let durationSeconds = try Self.parseDuration(lastStr)
            startMs = endMs - Int64(durationSeconds * 1000)
        } else if let fromStr = from {
            startMs = try Self.parseTime(fromStr)
        } else {
            throw CleanExit.message("Specify either --last or --from.")
        }

        let store = CaptureStore(dataDir: dataDir)
        var records = try store.readRecords(from: startMs, to: endMs)
        records.sort { lhs, rhs in
            timeMs(of: lhs) < timeMs(of: rhs)
        }

        if detail {
            for record in records {
                switch record {
                case let r as ScreenshotRecord:
                    let paths = CaptureStore.resolvePaths(for: r.id)
                    let detailRecord = ScreenshotDetailRecord(
                        id: r.id,
                        unixTimeMs: r.unixTimeMs,
                        url: r.url,
                        app: r.app,
                        title: r.title,
                        isFocused: r.isFocused,
                        isPlayingMedia: r.isPlayingMedia,
                        appContext: r.appContext,
                        path: paths.screenshot,
                        available: paths.screenshot != nil
                    )
                    let line = try CaptureRecordCoder.encodeDetail(detailRecord)
                    print(line)
                case let r as CameraRecord:
                    let paths = CaptureStore.resolvePaths(for: r.id)
                    let detailRecord = CameraDetailRecord(
                        id: r.id,
                        unixTimeMs: r.unixTimeMs,
                        path: paths.camera,
                        available: paths.camera != nil
                    )
                    let line = try CaptureRecordCoder.encodeDetail(detailRecord)
                    print(line)
                default:
                    let line = try CaptureRecordCoder.encode(record)
                    print(line)
                }
            }
        } else {
            // Index mode: all records but without tmp file paths
            for record in records {
                let line = try CaptureRecordCoder.encode(record)
                print(line)
            }
        }
    }

    // MARK: - Time Parsing

    static func parseTime(_ str: String) throws -> Int64 {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: str) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        let localISO = DateFormatter()
        localISO.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        localISO.timeZone = .current
        if let date = localISO.date(from: str) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        let timeOnly = DateFormatter()
        timeOnly.dateFormat = "HH:mm"
        timeOnly.timeZone = .current
        if let parsed = timeOnly.date(from: str) {
            let calendar = Calendar.current
            let now = Date()
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            let timeComponents = calendar.dateComponents([.hour, .minute], from: parsed)
            components.hour = timeComponents.hour
            components.minute = timeComponents.minute
            components.second = 0
            if let date = calendar.date(from: components) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }

        throw ValidationError("Invalid time format: \(str). Use ISO 8601 or HH:mm.")
    }

    // MARK: - Duration Parsing

    static func parseDuration(_ str: String) throws -> Double {
        if let seconds = Double(str) {
            return seconds
        }

        var remaining = str[str.startIndex...]
        var totalSeconds: Double = 0
        var matched = false

        while !remaining.isEmpty {
            let digits = remaining.prefix(while: { $0.isNumber || $0 == "." })
            guard !digits.isEmpty, let value = Double(digits) else {
                throw ValidationError("Invalid duration format: \(str). Use formats like 30m, 1h, 2h30m.")
            }
            remaining = remaining[digits.endIndex...]

            guard let unit = remaining.first else {
                throw ValidationError("Invalid duration format: \(str). Missing unit (h/m/s).")
            }
            switch unit {
            case "h": totalSeconds += value * 3600
            case "m": totalSeconds += value * 60
            case "s": totalSeconds += value
            default:
                throw ValidationError("Invalid duration unit '\(unit)' in: \(str). Use h, m, or s.")
            }
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
            matched = true
        }

        guard matched else {
            throw ValidationError("Invalid duration format: \(str).")
        }
        return totalSeconds
    }

    // MARK: - Schema

    static let schemaText = """
    yap context outputs NDJSON (one JSON object per line). Each record has a "type" field.

    ## Record Types

    ### screenshot
    Screen capture metadata. Taken periodically from each display.
    - type: "screenshot"
    - id: string — unique ID, use with --detail to resolve file paths
    - unixTimeMs: number — capture timestamp (Unix ms)
    - app: string — foreground app name
    - title: string? — window title
    - url: string? — browser URL (if applicable)
    - is_focused: boolean — whether this display had user focus
    - is_playing_media: boolean — whether media was detected

    With --detail, adds:
    - path: string? — screenshot image file path
    - available: boolean — whether the image file exists
    - ocr_path: string? — OCR text file path
    - ocr_available: boolean — whether the OCR file exists

    ### transcription
    Speech-to-text from the microphone.
    - type: "transcription"
    - unixTimeMs: number — speech timestamp (Unix ms)
    - text: string — transcribed text

    ### camera
    Camera image metadata (when --camera is used with yap capture).
    - type: "camera"
    - id: string — unique ID
    - unixTimeMs: number — capture timestamp (Unix ms)

    With --detail, adds:
    - path: string? — camera image file path
    - available: boolean — whether the image file exists

    ### summary
    Analysis results written by external tools to {data-dir}/summaries/.
    - type: "summary"
    - fromUnixTimeMs: number — analysis period start (Unix ms)
    - toUnixTimeMs: number — analysis period end (Unix ms)
    - text: string — analysis text

    ## Usage

    # Get last 30 minutes of activity
    yap context --data-dir <path> --last 30m

    # Get full details including file paths
    yap context --data-dir <path> --last 30m --detail

    # Specific time range
    yap context --data-dir <path> --from 10:00 --to 11:00

    ## Tips for analysis
    - Records are sorted by timestamp
    - screenshot records show what app/page the user was looking at
    - transcription records show what the user was saying
    - is_focused: true indicates the display the user was actively using
    - Summarize activity in 1-2 sentences per time period
    """
}

private func timeMs(of record: any CaptureRecord) -> Int64 {
    switch record {
    case let r as ScreenshotRecord: return r.unixTimeMs
    case let r as TranscriptionRecord: return r.unixTimeMs
    case let r as CameraRecord: return r.unixTimeMs
    case let r as SummaryRecord: return r.fromUnixTimeMs
    default: return 0
    }
}
