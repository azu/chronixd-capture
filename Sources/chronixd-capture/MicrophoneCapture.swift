@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import Speech

// MARK: - MicrophoneCapture

final class MicrophoneCapture: @unchecked Sendable {
    // MARK: Lifecycle

    init(targetFormat: AVAudioFormat, inputContinuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.targetFormat = targetFormat
        self.inputContinuation = inputContinuation
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CaptureError.microphonePermissionDenied
        }
        guard let initialConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.noCompatibleAudioFormat
        }
        converter = initialConverter
        inputSampleRate = inputFormat.sampleRate
        currentDeviceName = Self.currentInputDeviceName()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Internal

    let audioEngine: AVAudioEngine
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    let targetFormat: AVAudioFormat
    nonisolated(unsafe) private(set) var converter: AVAudioConverter
    nonisolated(unsafe) private var configChangeObserver: NSObjectProtocol?
    private let reconfigureLock = NSLock()

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

    /// Current input device's localized name. nil if lookup fails.
    nonisolated(unsafe) private(set) var currentDeviceName: String?
    /// Sample rate of the input format. Used to compute audio time for RMS samples.
    nonisolated(unsafe) private var inputSampleRate: Double = 0
    /// Cumulative frames yielded to SpeechAnalyzer (in target sample rate units).
    /// Used as the audio timeline that aligns with `SpeechTranscriber.Result.range`.
    nonisolated(unsafe) private var framesSentToAnalyzer: AVAudioFramePosition = 0
    private let rmsBuffer = RMSRingBuffer()

    /// Returns the average RMS over `[startSec, endSec]` of the audio timeline.
    /// Returns nil if no samples fall within the range.
    func averageRMS(fromAudioTimeSec startSec: Double, toAudioTimeSec endSec: Double) -> Float? {
        rmsBuffer.average(from: startSec, to: endSec)
    }

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

    private func handleConfigurationChange() {
        reconfigureLock.lock()
        defer { reconfigureLock.unlock() }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let newInputFormat = inputNode.outputFormat(forBus: 0)
        guard newInputFormat.sampleRate > 0 else {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[capture] Audio engine reconfigured but input has no sample rate; skipping restart\n".utf8))
            }
            return
        }
        guard let newConverter = AVAudioConverter(from: newInputFormat, to: targetFormat) else {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[capture] Failed to rebuild AVAudioConverter after configuration change\n".utf8))
            }
            return
        }
        converter = newConverter
        inputSampleRate = newInputFormat.sampleRate
        currentDeviceName = Self.currentInputDeviceName()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        do {
            try audioEngine.start()
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[capture] Audio engine restarted after configuration change (sampleRate=\(newInputFormat.sampleRate))\n".utf8))
            }
        } catch {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[capture] Failed to restart audio engine after configuration change: \(error)\n".utf8))
            }
        }
    }

    private func sendSilentBuffer(frameLength: AVAudioFrameCount) {
        let frameCapacity = AVAudioFrameCount(
            ceil(Double(frameLength) * targetFormat.sampleRate / converter.inputFormat.sampleRate)
        )
        guard frameCapacity > 0,
              let silentBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
        silentBuffer.frameLength = frameCapacity
        // Buffer is already zero-filled on creation
        inputContinuation.yield(AnalyzerInput(buffer: silentBuffer))
        recordRMS(0, framesAdvanced: silentBuffer.frameLength)
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
        var rms: Float = 0
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sumOfSquares: Float = 0
            vDSP_svesq(channelData[0], 1, &sumOfSquares, vDSP_Length(frames))
            rms = sqrt(sumOfSquares / Float(max(frames, 1)))
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
            recordRMS(rms, framesAdvanced: convertedBuffer.frameLength)
        }
    }

    /// Append the RMS sample at the midpoint of the most recently yielded buffer
    /// and advance the analyzer-side audio timeline by `framesAdvanced` frames.
    private func recordRMS(_ rms: Float, framesAdvanced: AVAudioFrameCount) {
        guard targetFormat.sampleRate > 0 else { return }
        let midFrame = framesSentToAnalyzer + AVAudioFramePosition(framesAdvanced / 2)
        let midTimeSec = Double(midFrame) / targetFormat.sampleRate
        rmsBuffer.append(audioTimeSec: midTimeSec, rms: rms)
        framesSentToAnalyzer += AVAudioFramePosition(framesAdvanced)
    }

    private static func currentInputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            0, nil,
            &size,
            &deviceID
        )
        guard getStatus == noErr, deviceID != 0 else { return nil }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(nameSize)) { rawPtr in
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, rawPtr)
            }
        }
        guard nameStatus == noErr, let unmanaged = name else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}

// MARK: - RMSRingBuffer

private final class RMSRingBuffer: @unchecked Sendable {
    private struct Sample {
        let audioTimeSec: Double
        let rms: Float
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    /// Drop samples older than this many seconds before the newest sample.
    private let retentionSec: Double = 60.0

    func append(audioTimeSec: Double, rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(Sample(audioTimeSec: audioTimeSec, rms: rms))
        let cutoff = audioTimeSec - retentionSec
        if let firstFresh = samples.firstIndex(where: { $0.audioTimeSec >= cutoff }), firstFresh > 0 {
            samples.removeFirst(firstFresh)
        }
    }

    func average(from startSec: Double, to endSec: Double) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard endSec >= startSec else { return nil }
        var sum: Double = 0
        var count = 0
        for sample in samples where sample.audioTimeSec >= startSec && sample.audioTimeSec <= endSec {
            sum += Double(sample.rms)
            count += 1
        }
        guard count > 0 else { return nil }
        return Float(sum / Double(count))
    }
}
