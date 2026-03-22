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

    /// Capture a single frame from a device.
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

        return await withCheckedContinuation { continuation in
            let delegate = SingleFrameDelegate { sampleBuffer in
                session.stopRunning()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continuation.resume(returning: nil)
                    return
                }
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
                continuation.resume(returning: cgImage)
            }
            // Keep delegate alive via associated object
            objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "yap.camera.\(device.uniqueID)"))
            session.startRunning()
        }
    }

    /// No-op for API compatibility. Sessions are not persistent.
    func stop() {}
}

// MARK: - SingleFrameDelegate

private final class SingleFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CMSampleBuffer) -> Void)?

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?(sampleBuffer)
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
