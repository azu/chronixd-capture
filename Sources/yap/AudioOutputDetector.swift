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

    /// Thread-safe one-shot continuation wrapper.
    private final class OneShotContinuation: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: Bool) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }
    }

    /// Returns true if media is actively playing (playbackRate > 0).
    /// Must be called from a non-MainActor context (e.g. Task.detached).
    static func isMediaPlaying() async -> Bool {
        guard let getInfo = getInfoFunc else { return false }

        return await withCheckedContinuation { rawContinuation in
            let cont = OneShotContinuation(rawContinuation)
            // MediaRemote requires main queue for callbacks
            getInfo(DispatchQueue.main) { info in
                let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                cont.resume(returning: rate > 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                cont.resume(returning: false)
            }
        }
    }
}
