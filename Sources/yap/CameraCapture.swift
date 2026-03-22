@preconcurrency import AVFoundation
import CoreImage
import CoreMedia

// MARK: - CameraCapture

final class CameraCapture: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [(session: AVCaptureSession, deviceID: String)] = []
    private var delegates: [FrameDelegate] = []
    private var latestFrames: [String: CMSampleBuffer] = [:]
    private let ciContext = CIContext()

    /// Initialize with device IDs and start capture sessions.
    init(deviceIDs: [String]) throws {
        super.init()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        for id in deviceIDs {
            guard let device = discovery.devices.first(where: { $0.uniqueID == id }) else {
                let available = discovery.devices.map { "\($0.localizedName)\t\($0.uniqueID)" }.joined(separator: "\n")
                throw CameraCaptureError.deviceNotFound(id: id, available: available)
            }
            let session = AVCaptureSession()
            session.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CameraCaptureError.cannotAddInput(id: id)
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            let delegateHandler = FrameDelegate(deviceID: id) { [weak self] deviceID, sampleBuffer in
                self?.updateFrame(deviceID: deviceID, sampleBuffer: sampleBuffer)
            }
            output.setSampleBufferDelegate(delegateHandler, queue: DispatchQueue(label: "yap.camera.\(id)"))
            guard session.canAddOutput(output) else {
                throw CameraCaptureError.cannotAddOutput(id: id)
            }
            session.addOutput(output)

            delegates.append(delegateHandler)
            session.startRunning()
            sessions.append((session: session, deviceID: id))
        }
    }

    /// Get the latest frame from all configured cameras as CGImages.
    func captureAll() -> [(deviceID: String, image: CGImage)] {
        lock.lock()
        let frames = latestFrames
        lock.unlock()

        var results: [(deviceID: String, image: CGImage)] = []
        for (_, id) in sessions {
            guard let sampleBuffer = frames[id],
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { continue }
            results.append((deviceID: id, image: cgImage))
        }
        return results
    }

    /// Stop all capture sessions.
    func stop() {
        for (session, _) in sessions {
            session.stopRunning()
        }
    }

    private func updateFrame(deviceID: String, sampleBuffer: CMSampleBuffer) {
        lock.lock()
        latestFrames[deviceID] = sampleBuffer
        lock.unlock()
    }
}

// MARK: - FrameDelegate

private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let deviceID: String
    let handler: (String, CMSampleBuffer) -> Void

    init(deviceID: String, handler: @escaping (String, CMSampleBuffer) -> Void) {
        self.deviceID = deviceID
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(deviceID, sampleBuffer)
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
