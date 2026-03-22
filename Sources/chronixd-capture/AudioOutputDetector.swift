import Foundation

/// Checks if media is currently playing using the system NowPlaying info (MediaRemote).
enum AudioOutputDetector {
    /// Returns true if media is actively playing (playbackRate > 0).
    /// Spawns a short-lived process to query MediaRemote, avoiding RunLoop issues.
    static func isMediaPlaying() async -> Bool {
        let script = """
        import Foundation
        typealias F = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let b = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))!
        let p = CFBundleGetFunctionPointerForName(b, "MRMediaRemoteGetNowPlayingInfo" as CFString)!
        let f = unsafeBitCast(p, to: F.self)
        f(DispatchQueue.main) { info in
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            print(rate > 0 ? "1" : "0")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("0"); exit(0) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        print("0"); exit(0)
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                continuation.resume(returning: output == "1")
            }
        }
    }
}
