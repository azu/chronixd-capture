# Camera Capture for Context-Aware Dictation

## Overview

dictate サブコマンドにカメラ（ウェブカム）キャプチャ機能を追加する。スクリーンショットと並行してカメラ画像を取得し、LLM に渡すことで物理環境（手元の資料、食事、雰囲気など）をコンテキストとして活用する。

## Requirements

- `--camera <deviceID>` オプションで使用するカメラを指定（複数指定可）
- `yap cameras` サブコマンドで接続中カメラの一覧（名前 + ID）を表示
- カメラ画像はスクリーンショットと同じタイミング（1.5秒スロットル）で取得
- 画像は max 1280px にリサイズ
- 保存先はスクショと同じディレクトリ（`/tmp/yap/YYYYMMDD-HHmmss/camera-<id>.png`）
- Claude / MLX バックエンドに画像を渡す。Local (FoundationModels) は画像非対応なので無視

## Architecture

### New Files

#### `CameraCapture.swift`

独立したカメラキャプチャモジュール。AVCaptureSession を管理する。

```swift
final class CameraCapture: Sendable {
    /// Initialize with device IDs. Sessions are started immediately.
    init(deviceIDs: [String]) async throws

    /// Capture a snapshot from all configured cameras.
    /// Returns array of (deviceID, CGImage) pairs.
    func captureAll() async throws -> [(deviceID: String, image: CGImage)]

    /// Stop all capture sessions.
    func stop()
}
```

- カメラごとに独立した `AVCaptureSession` + `AVCapturePhotoOutput` を保持
- dictate 開始時にセッション起動、終了時に stop
- `captureAll()` は全カメラから並行でスナップショット取得
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

### Modified Files

#### `Yap.swift`

subcommands に `Cameras.self` を追加。

#### `Dictate.swift`

- `--camera <id>` オプション追加（`Array<String>` で複数指定可）
- `run()` 内で `CameraCapture` を初期化
- 既存の `captureWithScreenshots()` 呼び出し箇所で、カメラキャプチャも並行実行
- カメラ画像を `ScreenContext` に含める（または並列で渡す）

#### `ScreenContextCapture.swift` / Data Model

`ScreenContext` にカメラ画像情報を追加:

```swift
struct CameraContext: Sendable {
    let deviceID: String
    let imagePath: String?
}

struct ScreenContext: Sendable {
    let displays: [DisplayContext]
    let cameras: [CameraContext]  // new
    let timestamp: Date
}
```

#### `ClaudeCorrector.swift`

プロンプト構築時にカメラ画像パスを追加:

```
### Camera (deviceID)
Photo (read this file): /tmp/yap/.../camera-<id>.png
```

#### `MLXCorrector.swift`

`images` 配列にカメラ画像を追加（スクショと同列）。

#### `TranscriptionCorrector.swift`

変更なし（FoundationModels は画像非対応）。

### Capture Flow

```
dictate start
  ├── CameraCapture.init(deviceIDs) -- AVCaptureSession 起動
  └── ...

transcription result received (1.5s throttle)
  ├── ScreenContextCapture.captureWithScreenshots()  -- 既存
  ├── CameraCapture.captureAll()                     -- 新規（並行）
  ├── save camera images to /tmp/yap/.../camera-<id>.png
  ├── build ScreenContext (displays + cameras)
  └── corrector.correct(text, context)
```

### Image Handling

- `AVCapturePhotoOutput.capturePhoto()` で JPEG/HEIF → CGImage
- max 1280px にリサイズ（既存のスクショリサイズロジックを共有）
- PNG で保存（スクショと同じ形式）
- 保存ディレクトリ・クリーンアップは既存ロジックを再利用

### Permissions

- カメラアクセスには `NSCameraUsageDescription` が必要
- CLI ツールなので Info.plist に追加、または TCC を直接処理
- 権限がない場合は起動時にエラーメッセージを表示

## Error Handling

- 指定された deviceID が見つからない → 起動時エラー（利用可能なカメラ一覧を表示）
- キャプチャ中にカメラが切断 → そのカメラをスキップ、他のカメラは継続
- 権限拒否 → 起動時エラー

## Out of Scope

- wake word によるカメラ切り替え（将来対応）
- カメラ名での指定（ID のみ）
- `--camera all` オプション
- カメラ映像のストリーミング（静止画スナップショットのみ）
