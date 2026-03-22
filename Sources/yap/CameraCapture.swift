@preconcurrency import AVFoundation
import CoreImage
import CoreMedia

// MARK: - CameraCapture

/// Captures snapshots from specified cameras on demand (no persistent session).
final class CameraCapture: NSObject, @unchecked Sendable {
    private let devices: [(device: AVCaptureDevice, deviceID: String)]
    private let ciContext = CIContext()

    /// Initialize with device IDs. Validates that all devices exist but does NOT start sessions.
    init(deviceIDs: [String]) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        var resolved: [(device: AVCaptureDevice, deviceID: String)] = []
        for id in deviceIDs {
            guard let device = discovery.devices.first(where: { $0.uniqueID == id }) else {
                let available = discovery.devices.map { "\($0.localizedName)\t\($0.uniqueID)" }.joined(separator: "\n")
                throw CameraCaptureError.deviceNotFound(id: id, available: available)
            }
            resolved.append((device: device, deviceID: id))
        }
        self.devices = resolved
        super.init()
    }

    /// Capture a snapshot from all configured cameras.
    /// Starts a session per camera, grabs one frame, then stops.
    func captureAll() async -> [(deviceID: String, image: CGImage)] {
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for (device, id) in devices {
                group.addTask {
                    let image = await self.captureFrame(from: device)
                    return (id, image)
                }
            }
            var results: [(deviceID: String, image: CGImage)] = []
            for await (id, image) in group {
                if let image {
                    results.append((deviceID: id, image: image))
                }
            }
            return results
        }
    }

    /// Capture a single frame from a device with a 3-second timeout.
    private func captureFrame(from device: AVCaptureDevice) async -> CGImage? {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        // Guard to ensure continuation is resumed exactly once
        let once = OnceGuard()

        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let delegate = WarmupFrameDelegate(ciContext: self.ciContext) { cgImage in
                session.stopRunning()
                if once.claim() {
                    continuation.resume(returning: cgImage)
                }
            }
            objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "yap.camera.\(device.uniqueID)"))
            session.startRunning()

            // Timeout: return nil after 3 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                session.stopRunning()
                if once.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// No-op for API compatibility. Sessions are not persistent.
    func stop() {}
}

// MARK: - WarmupFrameDelegate

/// Skips initial black frames from camera warmup, returns the first valid frame.
private final class WarmupFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CGImage?) -> Void)?
    private let ciContext: CIContext
    private var frameCount = 0
    /// Maximum frames to wait before giving up (timeout ~2 seconds at 30fps)
    private let maxFrames = 60
    /// Minimum frames to skip for camera warmup
    private let skipFrames = 3

    init(ciContext: CIContext, handler: @escaping (CGImage?) -> Void) {
        self.ciContext = ciContext
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        frameCount += 1
        let count = frameCount
        guard let h = handler else {
            lock.unlock()
            return
        }

        // Skip initial warmup frames
        if count <= skipFrames {
            lock.unlock()
            return
        }

        // Timeout: return nil after maxFrames
        if count > maxFrames {
            handler = nil
            lock.unlock()
            h(nil)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.unlock()
            return
        }

        // Check if the frame is mostly black (camera still warming up)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            lock.unlock()
            return
        }

        if isBlackFrame(cgImage) {
            lock.unlock()
            return
        }

        handler = nil
        lock.unlock()
        h(cgImage)
    }

    /// Quick check if the image is mostly black by sampling a few pixels.
    private func isBlackFrame(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return true }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        // Sample 9 points across the image
        let positions = [
            (width / 4, height / 4), (width / 2, height / 4), (3 * width / 4, height / 4),
            (width / 4, height / 2), (width / 2, height / 2), (3 * width / 4, height / 2),
            (width / 4, 3 * height / 4), (width / 2, 3 * height / 4), (3 * width / 4, 3 * height / 4),
        ]

        var totalBrightness: Int = 0
        for (x, y) in positions {
            let offset = y * bytesPerRow + x * bytesPerPixel
            // BGRA format
            let b = Int(ptr[offset])
            let g = Int(ptr[offset + 1])
            let r = Int(ptr[offset + 2])
            totalBrightness += r + g + b
        }

        // Average brightness per sample point (max 765 = 255*3)
        let avgBrightness = totalBrightness / positions.count
        return avgBrightness < 15
    }
}

// MARK: - OnceGuard

/// Ensures a block runs at most once (thread-safe).
private final class OnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - CameraCaptureError

enum CameraCaptureError: Error, LocalizedError {
    case deviceNotFound(id: String, available: String)
    case cannotAddInput(id: String)
    case cannotAddOutput(id: String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id, let available):
            "Camera device not found: \(id)\nAvailable cameras:\n\(available)"
        case .cannotAddInput(let id):
            "Cannot add camera input for device: \(id)"
        case .cannotAddOutput(let id):
            "Cannot add camera output for device: \(id)"
        case .permissionDenied:
            "Camera permission is required. Grant it in System Settings > Privacy & Security > Camera."
        }
    }
}
