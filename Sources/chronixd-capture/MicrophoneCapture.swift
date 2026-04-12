@preconcurrency import AVFoundation
import Speech

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
            throw MicrophoneCaptureError.microphonePermissionDenied
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.noCompatibleAudioFormat
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

    /// Called when voice activity starts (silence -> speech transition).
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
            throw MicrophoneCaptureError.microphonePermissionDenied
        }
    }

    // MARK: Private

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted else {
            inSpeech = false
            silenceStartTime = nil
            return
        }
        // Voice Activity Detection: detect silence -> speech transition
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

// MARK: - MicrophoneCaptureError

enum MicrophoneCaptureError: Swift.Error, LocalizedError {
    case microphonePermissionDenied
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is required. Grant it in System Settings > Privacy & Security > Microphone."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        }
    }
}
