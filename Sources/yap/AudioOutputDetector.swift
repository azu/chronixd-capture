import Foundation

/// Checks if media is currently playing using the system NowPlaying info (MediaRemote).
enum AudioOutputDetector {
    private static let getInfoFunc: (
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    )? = {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else { return nil }
        guard let ptr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString
        ) else { return nil }
        return unsafeBitCast(ptr, to: (
            @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        ).self)
    }()

    /// Returns true if media is actively playing (playbackRate > 0).
    /// Returns false if paused, stopped, or if NowPlaying info is unavailable.
    @MainActor
    static func isMediaPlaying() async -> Bool {
        guard let getInfo = getInfoFunc else { return false }

        return await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            getInfo(DispatchQueue.main) { info in
                guard !resumed else { return }
                resumed = true
                let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                continuation.resume(returning: rate > 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
        }
    }
}
