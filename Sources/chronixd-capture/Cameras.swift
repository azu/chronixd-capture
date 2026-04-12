@preconcurrency import AVFoundation
import ArgumentParser

struct Cameras: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available cameras."
    )

    func run() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        if devices.isEmpty {
            print("No cameras found.")
            return
        }
        for device in devices {
            print("\(device.localizedName)\t\(device.uniqueID)")
        }
    }
}
