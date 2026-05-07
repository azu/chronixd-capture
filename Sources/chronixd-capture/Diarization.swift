import FluidAudio
import Foundation

// MARK: - DiarizationSegmentRecord

/// Sortformer から取得した確定済み segment を audio timeline 上で保持する内部表現。
struct DiarizationSegmentRecord: Sendable {
    let startSec: Double
    let endSec: Double
    let speakerLabel: String
}

// MARK: - DiarizationStream

/// FluidAudio Sortformer のストリーミング diarizer をラップする actor。
/// - 同セッション内のみ匿名 speaker_id を返す（cross-session 非対応）
/// - audio timeline は SpeechTranscriber.Result.range と同じ前提
actor DiarizationStream {
    private let diarizer: SortformerDiarizer
    private var segments: [DiarizationSegmentRecord] = []
    /// 直近 5 分のみ保持（メモリ抑制）
    private let retentionSec: Double = 300
    private var maxObservedEndSec: Double = -.infinity

    init() async throws {
        let config = SortformerConfig.default
        let timelineConfig = DiarizerTimelineConfig.sortformerDefault
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .cpuAndNeuralEngine)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    /// 16kHz mono Float32 の audio chunk を投入する。
    func addAudio(_ samples: [Float], sourceSampleRate: Double) throws {
        try diarizer.addAudio(samples, sourceSampleRate: sourceSampleRate)
    }

    /// 内部バッファを処理して finalized segment を取り込む。
    func processIfReady() throws {
        guard let update = try diarizer.process() else { return }
        appendSegments(from: update)
    }

    /// セッション終了時に未確定 segment を flush。
    func finalize() throws {
        if let update = try diarizer.finalizeSession() {
            appendSegments(from: update)
        }
    }

    /// 指定の audio time レンジに最も多く重なる speakerLabel を返す。
    func dominantSpeaker(from startSec: Double, to endSec: Double) -> String? {
        Self.dominantSpeaker(in: segments, from: startSec, to: endSec)
    }

    // MARK: Private

    private func appendSegments(from update: DiarizerTimelineUpdate) {
        guard !update.finalizedSegments.isEmpty else { return }
        for seg in update.finalizedSegments {
            let record = DiarizationSegmentRecord(
                startSec: Double(seg.startTime),
                endSec: Double(seg.endTime),
                speakerLabel: seg.speakerLabel
            )
            segments.append(record)
            if record.endSec > maxObservedEndSec {
                maxObservedEndSec = record.endSec
            }
        }
        let cutoff = maxObservedEndSec - retentionSec
        if let firstFresh = segments.firstIndex(where: { $0.endSec >= cutoff }), firstFresh > 0 {
            segments.removeFirst(firstFresh)
        }
    }

    /// pure logic、テスト容易性のため static func。
    static func dominantSpeaker(
        in segments: [DiarizationSegmentRecord],
        from startSec: Double,
        to endSec: Double
    ) -> String? {
        guard endSec > startSec else { return nil }
        var weights: [String: Double] = [:]
        for seg in segments {
            let overlapStart = max(seg.startSec, startSec)
            let overlapEnd = min(seg.endSec, endSec)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            weights[seg.speakerLabel, default: 0] += overlap
        }
        return weights.max(by: {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        })?.key
    }
}
