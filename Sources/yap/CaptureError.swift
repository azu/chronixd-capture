import Foundation

// MARK: - CaptureError

enum CaptureError: Swift.Error, LocalizedError {
    case speechTranscriberNotAvailable
    case unsupportedLocale
    case microphonePermissionDenied
    case noCompatibleAudioFormat
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied

    var errorDescription: String? {
        switch self {
        case .speechTranscriberNotAvailable:
            "SpeechTranscriber is not available on this device."
        case .unsupportedLocale:
            "The specified locale is not supported for speech transcription."
        case .microphonePermissionDenied:
            "Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone, then restart the terminal."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is required. Grant it in System Settings > Privacy & Security > Screen Recording."
        case .accessibilityPermissionDenied:
            "Accessibility permission is required. Grant it in System Settings > Privacy & Security > Accessibility."
        }
    }
}
