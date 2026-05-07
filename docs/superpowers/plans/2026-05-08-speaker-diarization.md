# Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FluidAudio Sortformer をリアルタイム streaming で動かし、`TranscriptionRecord` にセッション内匿名 `speaker_id` を付与する

**Architecture:** `MicrophoneCapture.handleBuffer` で converted buffer を SpeechAnalyzer に渡した直後、同じ buffer を fan-out callback で `DiarizationStream` actor にも渡す。Sortformer の `process()` を 1 秒間隔で別 Task で呼び、`finalizedSegments` を audio time 付きで蓄積。transcription consume 時に `result.range` と最大重なりの speaker_id を引き当てる。

**Tech Stack:** Swift 6.1, FluidAudio (Sortformer), AVFoundation, Speech, ArgumentParser

**Spec:** `docs/superpowers/specs/2026-05-07-speaker-diarization-design.md`

---

### Task 1: FluidAudio Package を依存追加してビルド確認

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Package.swift に FluidAudio dependency と product を追加**

`dependencies` 配列に追加:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.6.0"),
```

注: `from:` の値は最新安定版を `git ls-remote --tags https://github.com/FluidInference/FluidAudio.git | tail -5` で確認して指定。0.6.0 以上を最低限のバージョンとし、互換性を確保。

`targets` の `executableTarget` の `dependencies` に追加:

```swift
.product(name: "FluidAudio", package: "FluidAudio"),
```

- [ ] **Step 2: 依存解決とビルド確認**

```bash
swift package resolve 2>&1 | tail -10
swift build --disable-sandbox 2>&1 | tail -10
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add FluidAudio package dependency for speaker diarization"
```

---

### Task 2: TranscriptionRecord に speaker_id フィールドを追加

**Files:**
- Modify: `Sources/chronixd-capture/CaptureRecord.swift:39-47`

- [ ] **Step 1: TranscriptionRecord に speakerId フィールドと CodingKey を追加**

`TranscriptionRecord` を以下に置き換え:

```swift
struct TranscriptionRecord: CaptureRecord, Codable, Sendable {
    let type: CaptureRecordType = .transcription
    let unixTimeMs: Int64
    let endUnixTimeMs: Int64
    let rms: Float?
    let device: String?
    let speakerId: String?
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, unixTimeMs, text, rms, device
        case endUnixTimeMs = "end_unix_time_ms"
        case speakerId = "speaker_id"
    }
}
```

- [ ] **Step 2: ビルド確認（呼び出し側エラーが残るはず）**

```bash
swift build --disable-sandbox 2>&1 | tail -20
```

Expected: `Capture.swift` で `TranscriptionRecord(...)` 呼び出しが speakerId 不足でコンパイルエラー。これは Task 5 で修正する。

- [ ] **Step 3: 一旦呼び出し側で nil を渡してビルドを通す**

`Capture.swift` の `TranscriptionRecord(...)` 呼び出し（既存 `unixTimeMs:..., endUnixTimeMs:..., rms:..., device:..., text:...`）に `speakerId: nil,` を `text:` の直前に追加。

```bash
swift build --disable-sandbox 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/chronixd-capture/CaptureRecord.swift Sources/chronixd-capture/Capture.swift
git commit -m "feat: add speaker_id field to TranscriptionRecord"
```

---

### Task 3: Diarization.swift を作成して DiarizationStream actor を実装

**Files:**
- Create: `Sources/chronixd-capture/Diarization.swift`

- [ ] **Step 1: Diarization.swift を新規作成**

```swift
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

    init() async throws {
        let config = SortformerConfig.default
        let timelineConfig = DiarizerTimelineConfig.sortformerDefault
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .cpuAndNeuralEngine)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    /// 16kHz mono Float32 の audio chunk を投入する。
    /// `sourceSampleRate` は呼び出し側の実サンプルレート (typically 16000)。
    func addAudio(_ samples: [Float], sourceSampleRate: Double) throws {
        try diarizer.addAudio(samples, sourceSampleRate: sourceSampleRate)
    }

    /// 内部バッファを処理して finalized/tentative segment を取り込む。
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
    /// 該当 segment が無い場合は nil。
    func dominantSpeaker(from startSec: Double, to endSec: Double) -> String? {
        Self.dominantSpeaker(in: segments, from: startSec, to: endSec)
    }

    // MARK: Private

    private func appendSegments(from update: DiarizerTimelineUpdate) {
        for seg in update.finalizedSegments {
            segments.append(DiarizationSegmentRecord(
                startSec: Double(seg.startTime),
                endSec: Double(seg.endTime),
                speakerLabel: seg.speakerLabel
            ))
        }
        // retention: drop segments ending before `latestEnd - retentionSec`
        guard let latestEnd = segments.last?.endSec else { return }
        let cutoff = latestEnd - retentionSec
        if let firstFresh = segments.firstIndex(where: { $0.endSec >= cutoff }), firstFresh > 0 {
            segments.removeFirst(firstFresh)
        }
    }

    /// 重なり時間で重み付けして最大の speakerLabel を返す pure logic。
    /// テスト容易性のため static func として切り出し。
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
        return weights.max(by: { $0.value < $1.value })?.key
    }
}
```

- [ ] **Step 2: ビルド確認**

```bash
swift build --disable-sandbox 2>&1 | tail -10
```

Expected: `Build complete!`

API シグネチャ不一致でエラーが出た場合は FluidAudio 側のドキュメント (https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Sortformer.md) を確認して該当箇所を修正する。よくあるズレ:
- `SortformerConfig.default` が `.default()` (関数) の場合
- `SortformerModels.loadFromHuggingFace(config:computeUnits:)` の引数名違い
- `addAudio(_:sourceSampleRate:)` が throws でない場合

- [ ] **Step 3: Commit**

```bash
git add Sources/chronixd-capture/Diarization.swift
git commit -m "feat: add DiarizationStream actor wrapping FluidAudio Sortformer"
```

---

### Task 4: MicrophoneCapture に onConvertedBuffer callback を追加

**Files:**
- Modify: `Sources/chronixd-capture/MicrophoneCapture.swift:52-79, 200-208, 143-153`

- [ ] **Step 1: onConvertedBuffer プロパティを追加**

`MicrophoneCapture.swift` の `// MARK: Internal` セクション、`onSpeechStart` 宣言の直下に追加:

```swift
    /// Optional callback fired after each converted buffer is yielded to the analyzer.
    /// Use to fan out the same audio to a secondary consumer (e.g. diarization).
    nonisolated(unsafe) var onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)?
```

- [ ] **Step 2: handleBuffer の yield 直後で callback を呼ぶ**

`handleBuffer` の最後の if ブロックを以下に置き換え:

```swift
        if error == nil, convertedBuffer.frameLength > 0 {
            inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
            recordRMS(rms, framesAdvanced: convertedBuffer.frameLength)
            onConvertedBuffer?(convertedBuffer)
        }
```

- [ ] **Step 3: sendSilentBuffer でも同様に callback を呼ぶ（mute 中も diarization timeline を維持）**

`sendSilentBuffer` を以下に置き換え:

```swift
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
        onConvertedBuffer?(silentBuffer)
    }
```

- [ ] **Step 4: ビルド確認**

```bash
swift build --disable-sandbox 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/chronixd-capture/MicrophoneCapture.swift
git commit -m "feat: add onConvertedBuffer fan-out callback to MicrophoneCapture"
```

---

### Task 5: Capture.swift に --no-diarize フラグと DiarizationStream 統合

**Files:**
- Modify: `Sources/chronixd-capture/Capture.swift`

- [ ] **Step 1: --no-diarize フラグを Capture struct に追加**

`@Flag(name: .long, help: "Disable deduplication.") var noDedup: Bool = false` の直後に追加:

```swift
    @Flag(
        name: .long,
        help: "Disable speaker diarization (FluidAudio Sortformer)."
    ) var noDiarize: Bool = false
```

- [ ] **Step 2: targetFormat 取得後に DiarizationStream を初期化**

`run()` 関数内、`guard let targetFormat = ...` の後、`let capture = try MicrophoneCapture(...)` の直前に追加:

```swift
        // Initialize speaker diarization (default-on, opt out with --no-diarize)
        let formatOK = targetFormat.sampleRate == 16000
            && targetFormat.channelCount == 1
            && targetFormat.commonFormat == .pcmFormatFloat32
        let diarization: DiarizationStream?
        if noDiarize {
            diarization = nil
        } else if !formatOK {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data(
                    "[diarize] Skipped: targetFormat is not 16kHz mono Float32 (sampleRate=\(targetFormat.sampleRate), channels=\(targetFormat.channelCount))\n".utf8
                ))
            }
            diarization = nil
        } else {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[diarize] Initializing Sortformer (model download on first run)…\n".utf8))
            }
            do {
                diarization = try await DiarizationStream()
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[diarize] Ready.\n".utf8))
                }
            } catch {
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[diarize] Init failed (\(error)). Continuing without speaker diarization.\n".utf8))
                }
                diarization = nil
            }
        }
```

- [ ] **Step 3: capture 起動後に audio fan-out を配線**

`try capture.start()` の直前に追加:

```swift
        if let diarization {
            let diarizationRef = diarization
            capture.onConvertedBuffer = { buffer in
                guard let samples = Self.extractFloatSamples(from: buffer) else { return }
                Task { try? await diarizationRef.addAudio(samples, sourceSampleRate: 16000) }
            }
        }
```

- [ ] **Step 4: extractFloatSamples ヘルパーを Capture struct の末尾に追加**

`Capture` struct の最後（`func validate() throws { ... }` のあとに既存メソッドが並ぶエリア）にメソッドを追加。なお static にして @MainActor 制約を回避:

```swift
    static func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return nil }
        guard let channelData = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let ptr = UnsafeBufferPointer(start: channelData[0], count: frames)
        return Array(ptr)
    }
```

- [ ] **Step 5: process() を 1 秒間隔で呼ぶ Task を追加**

`mediaCheckTask` の Task.detached の直後（`let consumeTask = Task.detached { ... }` の直前）に追加:

```swift
        // Background task: drive Sortformer process() at 1 Hz
        let diarizationProcessTask: Task<Void, Never>? = if let diarization {
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    try? await diarization.processIfReady()
                }
            }
        } else {
            nil
        }
```

- [ ] **Step 6: transcription consume task で speakerId を引き当てる**

既存の `consumeTask` 内、`transcriptionBuffer.append(...)` の直前に挿入し、`speakerId: nil,` を実値に置き換える。consume task を以下に置き換え:

```swift
        // Background task 1: consume transcriber results into buffer
        let consumeCapture = capture
        let consumeDiarization = diarization
        let consumeTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let startSec = result.range.start.seconds
                    let durSec = result.range.duration.seconds
                    let endSec = startSec + durSec
                    let startMs = engineStartUnixMs + Int64(startSec * 1000)
                    let endMs = engineStartUnixMs + Int64(endSec * 1000)
                    let rms = consumeCapture.averageRMS(fromAudioTimeSec: startSec, toAudioTimeSec: endSec)
                    let device = consumeCapture.currentDeviceName
                    let speakerId = await consumeDiarization?.dominantSpeaker(from: startSec, to: endSec)
                    transcriptionBuffer.append(TranscriptionSegment(
                        startUnixMs: startMs,
                        endUnixMs: endMs,
                        text: text,
                        rms: rms,
                        device: device,
                        speakerId: speakerId
                    ))
                }
            } catch {
                // Transcriber ended (e.g. after finalize)
            }
        }
```

- [ ] **Step 7: TranscriptionSegment 構造体に speakerId を追加**

`Capture.swift` 末尾の `private struct TranscriptionSegment` を以下に置き換え:

```swift
private struct TranscriptionSegment: Sendable {
    let startUnixMs: Int64
    let endUnixMs: Int64
    let text: String
    let rms: Float?
    let device: String?
    let speakerId: String?
}
```

- [ ] **Step 8: Transcription record build 箇所を speakerId を渡すよう更新**

既存の `records.append(TranscriptionRecord(... speakerId: nil, text: segment.text))` を以下に変更:

```swift
                for segment in segments {
                    records.append(TranscriptionRecord(
                        unixTimeMs: segment.startUnixMs,
                        endUnixTimeMs: segment.endUnixMs,
                        rms: segment.rms,
                        device: segment.device,
                        speakerId: segment.speakerId,
                        text: segment.text
                    ))
                }
```

- [ ] **Step 9: SIGINT 時の shutdown で diarization を finalize**

shutdown task 内、`captureTimerTask.cancel()` の直前に追加:

```swift
            diarizationProcessTask?.cancel()
            try? await diarization?.finalize()
```

- [ ] **Step 10: ビルド確認**

```bash
swift build --disable-sandbox 2>&1 | tail -10
```

Expected: `Build complete!`

エラーが出た場合の典型例:
- `await consumeDiarization?.dominantSpeaker(...)` が actor isolation エラー → 既に `await` あるので OK のはずだが、Sendable 警告が出たら無視するか `@unchecked Sendable` 付与
- `diarizationProcessTask?.cancel()` が `nonisolated` warning → そのまま許容

- [ ] **Step 11: Commit**

```bash
git add Sources/chronixd-capture/Capture.swift
git commit -m "feat: integrate DiarizationStream into Capture loop with --no-diarize flag"
```

---

### Task 6: 動作確認

**Files:** なし（手動検証のみ）

- [ ] **Step 1: --no-diarize で従来挙動を確認**

```bash
mkdir -p /tmp/chronixd-no-diarize
swift build --disable-sandbox -c release 2>&1 | tail -3
.build/release/chronixd-capture capture --data-dir /tmp/chronixd-no-diarize --interval 5 --no-diarize &
CAPTURE_PID=$!
sleep 30
kill -INT $CAPTURE_PID
wait $CAPTURE_PID 2>/dev/null
find /tmp/chronixd-no-diarize -name "*.ndjson" -exec cat {} \; | grep '"type":"transcription"' | head -3
```

Expected: transcription レコードに `speaker_id` フィールドが**無い**こと（Optional + nil → 省略）。

- [ ] **Step 2: default-on で diarization 動作確認**

事前に macOS の System Settings > Sound > Input で内蔵マイクが選択されていることを確認。

```bash
mkdir -p /tmp/chronixd-diarize
.build/release/chronixd-capture capture --data-dir /tmp/chronixd-diarize --interval 5 &
CAPTURE_PID=$!
# 30 秒以上、複数の人で話す（最低でも一人で長めに何か喋る）
echo "話してください..."
sleep 60
kill -INT $CAPTURE_PID
wait $CAPTURE_PID 2>/dev/null
find /tmp/chronixd-diarize -name "*.ndjson" -exec cat {} \; | grep '"type":"transcription"'
```

Expected:
- stderr に `[diarize] Initializing Sortformer...` と `[diarize] Ready.` が出る
- 初回はモデルダウンロードで時間がかかる（数十秒〜数分）
- transcription レコードに `"speaker_id":"Speaker 0"` 等が含まれる
- 複数話者で話した場合、segment ごとに異なる speaker_id が付く

- [ ] **Step 3: format 不一致時のフォールバック確認（オプション）**

外部 USB マイクで targetFormat が 48kHz 等になる場合、stderr に `[diarize] Skipped: targetFormat is not 16kHz...` が出て speaker_id が null になることを確認。検証用デバイスがなければ skip。

- [ ] **Step 4: メモリ・CPU 負荷の観察**

```bash
.build/release/chronixd-capture capture --data-dir /tmp/chronixd-diarize --interval 30 &
CAPTURE_PID=$!
sleep 60
ps -p $CAPTURE_PID -o %cpu,rss,command
kill -INT $CAPTURE_PID
```

Expected: CPU 5〜20% (Sortformer ANE 最適化で軽め)、RSS 数百MB 程度。極端に高ければ `process()` 頻度を下げる等のチューニング検討。

- [ ] **Step 5: 完了 commit (verification 用 diff があれば。なければ skip)**

```bash
git status
# 変更が無ければ commit 不要。あればここで動作確認のメモを README 等に追記して commit。
```

---

## Notes

- FluidAudio のモデル CoreML ファイルは初回ダウンロード時に `~/Library/Caches/` 配下に保存される。HOME ディレクトリの空き容量に注意（典型的に数百MB）。
- Sortformer は最大 4 話者まで。5 人以上の会議では誤帰属が起きるが、本仕様では許容。
- 1秒間隔の `processIfReady` は CPU 負荷が問題なら 2-3 秒に伸ばしても良い。レイテンシと負荷のトレードオフ。
- 既存 NDJSON へのバックフィルは行わない（spec の Out of Scope）。
