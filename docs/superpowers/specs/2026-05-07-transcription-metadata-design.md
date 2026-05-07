# Transcription Metadata for Speaker Disambiguation

## Overview

`TranscriptionRecord` に話者分離・コンテキスト補助のためのメタデータを付与する。FluidAudio などの enrollment ベース話者識別には依存せず、マイクから自然に取れるメタデータのみで「voice-dairy 等の消費側が誰の発話かを推測する手がかり」を残す。

主目的は対面複数話者会議シーン（例: 2026-05-07 の ito/55さん 混同のような誤帰属）での **手がかり情報の充実** であり、自動的な話者ID付与は本仕様の対象外。FluidAudio 統合は将来の別仕様で扱う。

## Requirements

`TranscriptionRecord` に以下の3項目を追加する。

| フィールド | 型 | 内容 |
|---|---|---|
| `end_unix_time_ms` | `Int64` | segment 終了時刻（unix ms） |
| `rms` | `Float?` | segment 区間の平均RMS (0.0〜1.0)。取得失敗時 null |
| `device` | `String?` | 入力デバイス名 (例: "MacBook Air Microphone")。取得失敗時 null |

既存の `unixTimeMs` の意味を「segment 開始時刻」に変更する（従来は SpeechAnalyzer result 受信時刻）。後方互換のためフィールド名・型は維持。

## Non-Goals

- 話者IDの自動付与（FluidAudio enrollment 等）
- ReSpeaker XVF3800 の DOA 取得
- Vision.framework によるアクティブスピーカー検出
- EventKit 参加者リストの付与（ユーザ判断で除外）

## Architecture

### Data Model

`Sources/chronixd-capture/CaptureRecord.swift`:

```swift
struct TranscriptionRecord: CaptureRecord, Codable, Sendable {
    let type: CaptureRecordType = .transcription
    let unixTimeMs: Int64           // segment 開始時刻（仕様変更）
    let endUnixTimeMs: Int64        // 新規: segment 終了時刻
    let rms: Float?                 // 新規: segment 平均RMS
    let device: String?             // 新規: 入力デバイス名
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, unixTimeMs, text, rms, device
        case endUnixTimeMs = "end_unix_time_ms"
    }
}
```

`?` で nullable とすることで RMS リングバッファが空・デバイス名取得失敗時にも壊れずに記録できる。

### Time Range Derivation

現在 `Capture.swift:240-243` は `Date()` を `transcriber.results` の受信時に取得しているため segment 終了直後の単一時刻しか持たない。SpeechTranscriber の `attributeOptions: [.audioTimeRange]` は既に有効なので、`SpeechTranscriber.Result.range` (CMTimeRange) から開始・終了時刻を算出する。

```swift
// engine.start() 直後にエンジン基点時刻を記録
let engineStartUnixMs = Int64(Date().timeIntervalSince1970 * 1000)

// transcriber.results consume 時
for try await result in transcriber.results {
    let range = result.range  // CMTimeRange
    let startMs = engineStartUnixMs + Int64(range.start.seconds * 1000)
    let endMs = startMs + Int64(range.duration.seconds * 1000)
    // ... TranscriptionSegment に詰める
}
```

精度は `audioEngine.start()` のバッファリング遅延分（〜100ms）ズレるが、用途上問題ない。configuration change 後に engine が restart された場合、`engineStartUnixMs` は更新されないが、SpeechAnalyzer 側のセッションも継続されているため audioTime も連続している前提で扱う（ズレが顕在化したら別途対応）。

### RMS Aggregation

`MicrophoneCapture.swift:147-148` で per-buffer RMS を既に計算している。これをタイムスタンプ付きリングバッファに溜め、segment の時間レンジで平均する。

```swift
// MicrophoneCapture.swift に追加
private struct RMSSample {
    let audioTimeSec: Double
    let rms: Float
}

private final class RMSRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [RMSSample] = []
    private let retentionSec: Double = 60.0

    func append(audioTimeSec: Double, rms: Float) { /* lock & append, drop old */ }
    func average(from startSec: Double, to endSec: Double) -> Float? { /* lock & filter & mean */ }
}
```

`handleBuffer` 内で audio time を算出（`AVAudioEngine.inputNode.lastRenderTime` の `sampleTime / sampleRate`）して append する。`Capture` 側の result 受信時に `range.start.seconds` 〜 `range.start.seconds + range.duration.seconds` で問い合わせる。

該当区間のサンプルが0件の場合は null を返す（mute 中・遅延時など）。

### Input Device Name

CoreAudio の `kAudioHardwarePropertyDefaultInputDevice` から `AudioDeviceID` を取得し、`kAudioObjectPropertyName` でローカライズ済み名前を取得する。

```swift
// MicrophoneCapture.swift に追加
nonisolated(unsafe) private(set) var currentDeviceName: String?

private static func currentInputDeviceName() -> String? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
    ) == noErr else { return nil }
    // deviceID から kAudioObjectPropertyName を CFString で取得
    // ...
}
```

呼び出すタイミング:
- `MicrophoneCapture.init` で初回取得
- `handleConfigurationChange` で再取得（AirPods 接続/切断・デバイス切替時）

### Capture.swift 変更

`transcriber.results` consume ループで result から時刻レンジを取得し、`MicrophoneCapture` に RMS とデバイス名を問い合わせて `TranscriptionSegment` に詰める。

```swift
private struct TranscriptionSegment: Sendable {
    let startUnixMs: Int64
    let endUnixMs: Int64
    let text: String
    let rms: Float?
    let device: String?
}
```

`flush()` 後に `TranscriptionRecord` を組み立てる箇所で 5 フィールドすべてを埋める。

## File Changes

| ファイル | 変更概要 | 行数概算 |
|---|---|---|
| `CaptureRecord.swift` | `TranscriptionRecord` に 3 フィールド追加、`endUnixTimeMs` の `CodingKeys` snake_case マッピング | +4 |
| `MicrophoneCapture.swift` | `RMSRingBuffer` 追加、audio time での append、device name 取得・更新 | +90 |
| `Capture.swift` | `engineStartUnixMs` 記録、result の `range` を時刻に変換、RMS/device 問合せ、`TranscriptionSegment` 拡張 | +25 |
| `CaptureStore.swift` | 変更なし（NDJSON エンコーダは透過） |  0 |

合計 **+120 行程度**、新規依存なし。

## Backward Compatibility

- 既存の `unixTimeMs` フィールドは保持（型・名前）。意味だけ「segment 終了時刻」→「開始時刻」に変わる。差分は ms オーダなので消費側で問題が起きるとは想定しない。
- 新規フィールドは `Optional` または default 値で読めるため、古い NDJSON を読み込む消費側コードは無変更で動く。
- 古いコードが新しい NDJSON を読む場合、追加フィールドは既存 `JSONDecoder` のデフォルト挙動で無視される。

## Testing

| 種類 | 内容 |
|---|---|
| 単体 | `RMSRingBuffer.average` のロジック（時刻フィルタ・平均計算・空時のnil返し）をテスト |
| 単体 | `audioTimeRange → unixTimeMs` 変換ロジックを純粋関数として切り出してテスト |
| 統合 | AVAudioEngine + SpeechAnalyzer は実機依存のため自動化困難。`chronixd-capture context --detail` の手動検証で確認 |
| 確認 | `swift build --disable-sandbox` が通ること、実行して NDJSON に新フィールドが書かれること |

## Risks

- **`AVAudioEngine.inputNode.lastRenderTime` の挙動**: configuration change 直後は nil を返すことがある。その場合は append をスキップし、復帰後のサンプルから再開する。
- **デバイス名のローカライズ**: 環境言語によって異なる文字列が入る。consumer 側でハードコードしないよう README に注記する。
- **engine restart 後の audio time 連続性**: SpeechAnalyzer は engine restart 後も同じセッションを使うが、`lastRenderTime` の sampleTime はリセットされる可能性がある。`engineStartUnixMs` を restart 時にも更新するか、AVAudioTime の差分計算に切り替えるか、実装時に挙動確認して判断する。

## Out of Scope (Future Work)

- FluidAudio 統合による匿名 speakerId 付与（オンライン clustering）
- 事前に置いた `~/.config/chronixd-capture/speakers/{name}.wav` での enrollment
- ReSpeaker XVF3800 接続時の DOA azimuth 付与
- 各 segment ごとの直近 5 秒音声 snippet 保存（手動アノテーション用）
