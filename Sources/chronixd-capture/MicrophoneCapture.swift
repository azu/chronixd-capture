@preconcurrency import AVFoundation
import Accelerate
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
            throw CaptureError.microphonePermissionDenied
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.noCompatibleAudioFormat
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

    /// Called when voice activity starts (silence → speech transition).
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
            throw CaptureError.microphonePermissionDenied
        }
    }

    // MARK: Private

    private func sendSilentBuffer(frameLength: AVAudioFrameCount) {
        let frameCapacity = AVAudioFrameCount(
            ceil(Double(frameLength) * targetFormat.sampleRate / converter.inputFormat.sampleRate)
        )
        guard frameCapacity > 0,
              let silentBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
        silentBuffer.frameLength = frameCapacity
        // Buffer is already zero-filled on creation
        inputContinuation.yield(AnalyzerInput(buffer: silentBuffer))
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        if isMuted {
            inSpeech = false
            silenceStartTime = nil
            // Send a silent buffer to keep SpeechAnalyzer alive and avoid
            // internal CheckedThrowingContinuation leaks in the Speech framework.
            sendSilentBuffer(frameLength: buffer.frameLength)
            return
        }
        // Voice Activity Detection: detect silence → speech transition
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sumOfSquares: Float = 0
            vDSP_svesq(channelData[0], 1, &sumOfSquares, vDSP_Length(frames))
            let rms = sqrt(sumOfSquares / Float(max(frames, 1)))
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
