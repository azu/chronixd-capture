# Camera Capture for Context-Aware Dictation

## Overview

dictate サブコマンドにカメラ（ウェブカム）キャプチャ機能を追加する。スクリーンショットと並行してカメラ画像を取得し、LLM に渡すことで物理環境（手元の資料、食事、雰囲気など）をコンテキストとして活用する。

## Requirements

- `--camera <deviceID>` オプションで使用するカメラを指定（複数指定可、`--camera id1 --camera id2`）
- `yap cameras` サブコマンドで接続中カメラの一覧（名前 + ID）を表示
- カメラ画像はスクリーンショットと同じタイミング（1.5秒スロットル）で取得
- 画像は max 1280px にリサイズ
- 保存先はスクショと同じディレクトリ（`/tmp/yap/YYYYMMDD-HHmmss/camera-<index>.png`）
- Claude / MLX バックエンドに画像を渡す。Local (FoundationModels) は画像非対応なので無視

## Architecture

### New Files

#### `CameraCapture.swift`

独立したカメラキャプチャモジュール。`AVCaptureVideoDataOutput` で最新フレームをキャッシュする方式。

```swift
final class CameraCapture: @unchecked Sendable {
    /// Initialize with device IDs. Sessions are started immediately.
    init(deviceIDs: [String]) async throws

    /// Get the latest frame from all configured cameras.
    /// Returns array of (deviceID, CGImage) pairs.
    /// Frames are cached by AVCaptureVideoDataOutputSampleBufferDelegate;
    /// this method reads the latest cached frame (no capture trigger needed).
    func captureAll() -> [(deviceID: String, image: CGImage)]

    /// Stop all capture sessions.
    func stop()
}
```

実装の詳細:

- カメラごとに独立した `AVCaptureSession` + `AVCaptureVideoDataOutput` を保持
- `AVCaptureVideoDataOutputSampleBufferDelegate` で最新の `CMSampleBuffer` をキャッシュ
- `captureAll()` はキャッシュ済みフレームを `CGImage` に変換して返す（低レイテンシ）
- `@unchecked Sendable` + NSLock で内部同期（既存の `MLXCorrector` と同じパターン）
- dictate 開始時にセッション起動、終了時に stop
- 指定された deviceID が見つからない場合はエラーで起動失敗

#### `Cameras.swift`

`yap cameras` サブコマンドの実装。

```swift
struct Cameras: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available cameras."
    )

    func run() throws {
        // AVCaptureDevice.DiscoverySession で一覧取得
        // "Name    ID" 形式で出力
    }
}
```

注意: macOS 14+ では `AVCaptureDevice.DiscoverySession` でデバイス一覧を取得する際にカメラ権限プロンプトが表示される可能性がある。

### Modified Files

#### `Yap.swift`

subcommands に `Cameras.self` を追加。

#### `Dictate.swift`

- `--camera <id>` オプション追加（ArgumentParser の `@Option` で repeated flag: `--camera id1 --camera id2`）
- `run()` 内で `CameraCapture` を初期化
- 既存の `captureWithScreenshots()` 呼び出し箇所で、カメラキャプチャも並行実行
- カメラ画像の保存ディレクトリは `captureWithScreenshots()` が返すパスを使う（ディレクトリ作成は ScreenContextCapture 側で行われる）
- `ScreenContext` の全構築箇所（通常キャプチャおよび空コンテキスト `ScreenContext(displays: [], timestamp: Date())`）を更新して `cameras` フィールドを含める

#### `ScreenContextCapture.swift` / Data Model

`ScreenContext` にカメラ画像情報を追加:

```swift
struct CameraContext: Sendable {
    let deviceID: String
    let imagePath: String?
}

struct ScreenContext: Sendable {
    let displays: [DisplayContext]
    let cameras: [CameraContext]  // new (default: [])
    let timestamp: Date
}
```

`captureWithScreenshots()` の戻り値またはパラメータを調整し、保存ディレクトリのパスを外部から取得できるようにする。カメラ画像の保存はこのディレクトリに `camera-0.png`, `camera-1.png` のようにインデックスベースで保存（deviceID にはファイル名に不適切な文字が含まれる可能性があるため）。

#### `ClaudeCorrector.swift`

プロンプト構築時にカメラ画像パスを追加:

```
### Camera
Photo (read this file): /tmp/yap/.../camera-0.png
```

#### `MLXCorrector.swift`

`images` 配列にカメラ画像を追加（スクショと同列）。

#### `TranscriptionCorrector.swift`

変更なし（FoundationModels は画像非対応）。`context.cameras` は無視される。

### Capture Flow

```
dictate start
  ├── CameraCapture.init(deviceIDs) -- AVCaptureSession 起動、フレームキャッシュ開始
  └── ...

transcription result received (1.5s throttle)
  ├── ScreenContextCapture.captureWithScreenshots()  -- 既存（ディレクトリ作成含む）
  ├── CameraCapture.captureAll()                     -- キャッシュ済みフレーム取得（並行）
  ├── save camera images to /tmp/yap/.../camera-N.png
  ├── build ScreenContext (displays + cameras)
  └── corrector.correct(text, context)
```

### Image Handling

- `AVCaptureVideoDataOutput` の delegate でフレームを連続キャッシュ
- `captureAll()` 時にキャッシュから `CMSampleBuffer` → `CGImage` 変換
- max 1280px にリサイズ（既存のスクショリサイズロジックを共有）
- PNG で保存（スクショと同じ形式）
- 保存ディレクトリ・クリーンアップは既存ロジックを再利用

### Permissions

- カメラアクセスには TCC 権限が必要
- CLI ツールのため、初回アクセス時にシステムが権限ダイアログを表示する
- `AVCaptureDevice.requestAccess(for: .video)` で明示的にリクエスト
- 権限がない場合は起動時にエラーメッセージを表示（ScreenCaptureKit の権限チェックと同じパターン）

### Debug Logging

`--debug` フラグ有効時、既存の `logScreenContext()` を拡張してカメラ情報も出力:

- キャプチャしたカメラ台数
- 各カメラの deviceID と保存パス

## Error Handling

- 指定された deviceID が見つからない → 起動時エラー（利用可能なカメラ一覧を表示）
- キャプチャ中にカメラが切断 → そのカメラをスキップ、他のカメラは継続
- 権限拒否 → 起動時エラー

## Out of Scope

- wake word によるカメラ切り替え（将来対応）
- カメラ名での指定（ID のみ）
- `--camera all` オプション
- カメラ映像のストリーミング（静止画スナップショットのみ）
