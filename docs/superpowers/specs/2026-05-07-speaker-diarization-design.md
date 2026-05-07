# Speaker Diarization via FluidAudio Sortformer

## Overview

`TranscriptionRecord` にセッション内で安定した匿名 `speaker_id` を付与する。FluidAudio の Sortformer モデルを使い、リアルタイム音声を SpeechAnalyzer と並列に diarization し、transcription の時間レンジと最も重なる speaker をその segment の話者として記録する。

主目的は対面複数話者会議シーン（例: 2026-05-07 の ito/55さん 混同）で、**同セッション内の発話を別話者として区別する** こと。日をまたいだ ID 一致（cross-session matching）や個人名への紐付けは本仕様の範囲外。

## Requirements

- `TranscriptionRecord` に `speaker_id: String?` を追加（Sortformer の "Speaker_1" 等をそのまま入れる）
- diarization は **default-on**。`--no-diarize` フラグで opt-out 可能
- モデルダウンロード・初期化失敗時は warning を出して null で続行（capture 自体は継続）
- 既存の transcription 出力タイミング（capture interval = 30s）に追従する形で speaker 割当

## Non-Goals

- cross-session の話者一致（Sortformer は非対応、別仕様で扱う）
- speaker_id への人間が読める名前付与（CLI ツール等）
- 話者数 5 人以上の会議（Sortformer 上限 4）

## Architecture

### Model Choice

Sortformer を採用。理由：

| | Sortformer | DiarizerManager (pyannote) |
|---|---|---|
| ストリーミングレイテンシ | ~1s | 3〜10s |
| Apple Silicon ANE 最適化 | ◎ | △ |
| 最大話者数 | 4 | 制限なし |
| cross-session embedding 永続化 | × | ◎ |
| 計算負荷 | 軽 | 重 |

ユーザー要件「日付ごとの ID は揃ってなくてよい」に合致するため、軽い Sortformer を選ぶ。話者数 5+ になる会議は scope 外。

### Data Model

`Sources/chronixd-capture/CaptureRecord.swift`:

```swift
struct TranscriptionRecord: CaptureRecord, Codable, Sendable {
    let type: CaptureRecordType = .transcription
    let unixTimeMs: Int64
    let endUnixTimeMs: Int64
    let rms: Float?
    let device: String?
    let speakerId: String?   // 新規: Sortformer 由来の匿名 ID
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, unixTimeMs, text, rms, device
        case endUnixTimeMs = "end_unix_time_ms"
        case speakerId = "speaker_id"
    }
}
```

null は「diarization 無効・モデル未ロード・対応 segment 未確定」のいずれか。

### Package Dependency

`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    .package(url: "https://github.com/tuist/Noora.git", from: "0.40.1"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "<latest stable>"),
],
targets: [
    .executableTarget(
        name: "chronixd-capture",
        dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Noora", package: "Noora"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]
    ),
]
```

最新安定版を実装時に確認して固定。

### New File: `Diarization.swift`

```swift
import FluidAudio
import Foundation

actor DiarizationStream {
    init() async throws
    
    /// 16kHz mono Float32 で音声を投入。framesSentToAnalyzer と同じ audio timeline。
    func addAudio(_ samples: [Float])
    
    /// 内部バッファが Sortformer の chunk 閾値を超えていたら process。
    func processIfReady() async throws
    
    /// SIGINT 等での終了時に未確定 segment を flush。
    func finalize() async throws
    
    /// 指定の audio time レンジに最も多く重なる speakerId を返す。
    /// 該当 segment が未確定・存在しない場合は nil。
    func dominantSpeaker(from startSec: Double, to endSec: Double) -> String?
}
```

内部:
- Sortformer インスタンスを保持
- `process()` が返す `finalizedSegments` を `[(startSec, endSec, speakerId)]` で蓄積
- 直近 5 分程度を保持し、それより古いものは drop（メモリ抑制）
- `dominantSpeaker` は重なり時間で重み付けし、最大の speaker を返す

### Audio Fan-out

`MicrophoneCapture` に optional callback を追加：

```swift
nonisolated(unsafe) var onConvertedBuffer: ((AVAudioPCMBuffer) -> Void)?
```

`handleBuffer` で `inputContinuation.yield` した直後、`onConvertedBuffer?(convertedBuffer)` を呼ぶ。

`Capture.swift` 側で:

```swift
capture.onConvertedBuffer = { [weak diarization] buffer in
    guard let diarization else { return }
    let samples = Self.extractFloatSamples(from: buffer)
    Task { await diarization.addAudio(samples) }
}
```

### Format Compatibility

Sortformer は 16kHz mono Float32 を要求する。`SpeechAnalyzer.bestAvailableAudioFormat` は典型的に同じフォーマットを返すため pass-through 想定。起動時に `targetFormat` の sampleRate / channels / commonFormat を確認し、不一致なら warning を出して diarization を無効化する。

### Time Alignment

`MicrophoneCapture.framesSentToAnalyzer` (target sample rate 単位の累積) と SpeechTranscriber の `result.range` は同じ timeline。同じ converted buffer を Sortformer にも渡すので、Sortformer 内部の audio time も同じ timeline になる。

`Capture.swift` の transcription consume task:

```swift
for try await result in transcriber.results {
    let startSec = result.range.start.seconds
    let endSec = startSec + result.range.duration.seconds
    let speakerId = await diarization?.dominantSpeaker(from: startSec, to: endSec)
    transcriptionBuffer.append(TranscriptionSegment(
        startUnixMs: ...,
        endUnixMs: ...,
        text: text,
        rms: ...,
        device: ...,
        speakerId: speakerId
    ))
}
```

`process()` は専用の `Task.detached` で 1 秒間隔で呼ぶ（capture interval の 30 秒では transcription flush 時の segment 確定漏れが多すぎるため別ループ）。

### CLI

`Capture` コマンドに opt-out フラグ:

```swift
@Flag(name: .long, help: "Disable speaker diarization (FluidAudio).")
var noDiarize: Bool = false
```

`--no-diarize` 指定時は `DiarizationStream` を初期化せず、speakerId は常に null。

### Lifecycle

1. capture 起動 → `--no-diarize` でなければ `DiarizationStream.init()` を await
2. モデル未ダウンロード時は FluidAudio が初回 DL を実行。ユーザーには stderr に `[diarize] Downloading models...` 程度のログを出す（既存 SpeechAnalyzer のアセット DL は Noora progress を使っているが、diarization は CLI 起動を遅延させたくないので簡易ログのみ）
3. 初期化失敗 → stderr に warning を出し、`diarization = nil` にして続行
4. capture timer interval ごとに `processIfReady()` を呼ぶ（1秒間隔の別タスクでも可）
5. SIGINT 時に `finalize()` を呼んで未確定 segment を flush（ベストエフォート）

### Failure Modes

| 状況 | 振る舞い |
|---|---|
| モデル DL 失敗 | warning 出して `diarization = nil`、null speaker_id で続行 |
| Sortformer init 失敗 | 同上 |
| `addAudio` で例外 | warning 出して以降の追加スキップ、既存 segment は使う |
| transcription flush 時に該当 segment 未確定 | speaker_id = null（後続 capture で再評価しない、欠損許容） |
| 5 人以上の話者 | Sortformer 仕様で4 話者にクラスタリングされる、誤帰属あり得る |

## File Changes

| ファイル | 変更概要 | 行数概算 |
|---|---|---|
| `Package.swift` | FluidAudio 依存追加 | +2 |
| `CaptureRecord.swift` | `speakerId` フィールド・CodingKey 追加 | +3 |
| `Diarization.swift` (新) | `DiarizationStream` actor | +130 |
| `MicrophoneCapture.swift` | `onConvertedBuffer` callback 追加 | +5 |
| `Capture.swift` | `--no-diarize` フラグ、初期化、process タイマー、speakerId 割当、finalize | +60 |

合計 **+200 行程度**、新規依存 1（FluidAudio + 推移依存）。

## Backward Compatibility

- `speaker_id` は Optional のため省略時に既存 NDJSON 消費側コードは無変更で動く
- 既存の `unixTimeMs` / `end_unix_time_ms` / `rms` / `device` / `text` は維持

## Testing

| 種類 | 内容 |
|---|---|
| 単体 | `DiarizationStream.dominantSpeaker` の重なり時間集計ロジック（モックの segment リストで） |
| 単体 | format 互換性チェック（16kHz mono Float32 でない時に diarization が無効化されるか） |
| 統合 | macOS 26 実機で `swift build --disable-sandbox -c release && chronixd-capture capture` を 1〜2 分実行し、複数話者の segment に異なる speaker_id が付与されるか NDJSON で目視確認 |
| 確認 | `--no-diarize` で従来通り speaker_id 無しの NDJSON が出ること |

## Risks

- **モデルダウンロードサイズ・時間**: 初回 DL 待ちが capture 起動を遅らせる。Noora progress で見せるか、バックグラウンド DL にして空 NDJSON を許容するかは実装時に判断。
- **format 不一致**: `bestAvailableAudioFormat` が将来 16kHz mono Float32 以外を返す可能性がある。検出して warning + 無効化で fallback。
- **process() の呼び出し頻度**: 高頻度だと CPU 負荷、低頻度だと segment 確定が遅い。1秒間隔で開始し、必要なら調整。
- **transcription と diarization の audio time ズレ**: 同じ converted buffer を渡す前提だが、`onConvertedBuffer` callback の async dispatch 中に順序が乱れると微小ズレが発生し得る。重なり判定に余裕をもたせる（±100ms tolerance）か、同期 dispatch にする。
- **Sortformer 4 話者上限**: 5 人以上の会議では誤帰属が起きる。spec 内に non-goal として明記。

## Out of Scope (Future Work)

- cross-session 話者一致（DiarizerManager + embedding 永続化）
- speaker_id への人間名割当 CLI（`chronixd-capture speakers name <id> <name>`）
- 過去 NDJSON へのバックフィル（diarization 後付け）
- ReSpeaker XVF3800 DOA との融合
