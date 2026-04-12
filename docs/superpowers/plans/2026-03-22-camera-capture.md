# Camera Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dictate サブコマンドにカメラキャプチャを追加し、スクリーンショットと一緒に LLM バックエンドに渡す

**Architecture:** `CameraCapture.swift` を新設し AVCaptureVideoDataOutput で最新フレームをキャッシュ。Dictate.swift からスクリーンキャプチャと並行呼び出し。ScreenContext に cameras フィールドを追加し、各 Corrector で画像パスを参照。

**Tech Stack:** Swift 6.1, AVFoundation, ArgumentParser

**Spec:** `docs/superpowers/specs/2026-03-22-camera-capture-design.md`

---

### Task 1: ScreenContext に CameraContext を追加

**Files:**
- Modify: `Sources/yap/ScreenContextCapture.swift:9-38`
- Modify: `Sources/yap/Dictate.swift:254-256, 305`

- [ ] **Step 1: CameraContext 構造体と ScreenContext の cameras フィールドを追加**

`ScreenContextCapture.swift` の `ScreenContext` の直前に追加:

```swift
struct CameraContext: Sendable {
    let deviceID: String
    let imagePath: String?
}
```

`ScreenContext` を変更:

```swift
struct ScreenContext: Sendable {
    let displays: [DisplayContext]
    let cameras: [CameraContext]
    let timestamp: Date
}
```

- [ ] **Step 2: ScreenContext 構築箇所をすべて修正**

`ScreenContextCapture.swift` の `capture()` と `captureWithScreenshots()`:

```swift
return ScreenContext(displays: displays, cameras: [], timestamp: Date())
```

`Dictate.swift` の `emptyContext` (line 254):

```swift
let emptyContext = ScreenContext(displays: [], cameras: [], timestamp: Date())
```

- [ ] **Step 3: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 4: Commit**

```bash
git add Sources/yap/ScreenContextCapture.swift Sources/yap/Dictate.swift
git commit -m "feat: add CameraContext to ScreenContext data model"
```

---

### Task 2: CameraCapture モジュールの実装

**Files:**
- Create: `Sources/yap/CameraCapture.swift`

- [ ] **Step 1: CameraCapture.swift を作成**

```swift
@preconcurrency import AVFoundation
import CoreMedia

// MARK: - CameraCapture

final class CameraCapture: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [(session: AVCaptureSession, deviceID: String)] = []
    private var delegates: [FrameDelegate] = []
    private var latestFrames: [String: CMSampleBuffer] = [:]
    private let ciContext = CIContext()

    /// Initialize with device IDs and start capture sessions.
    init(deviceIDs: [String]) throws {
        super.init()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        for id in deviceIDs {
            guard let device = discovery.devices.first(where: { $0.uniqueID == id }) else {
                let available = discovery.devices.map { "\($0.localizedName)\t\($0.uniqueID)" }.joined(separator: "\n")
                throw CameraCaptureError.deviceNotFound(id: id, available: available)
            }
            let session = AVCaptureSession()
            session.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CameraCaptureError.cannotAddInput(id: id)
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            let delegateHandler = FrameDelegate(deviceID: id) { [weak self] deviceID, sampleBuffer in
                self?.updateFrame(deviceID: deviceID, sampleBuffer: sampleBuffer)
            }
            output.setSampleBufferDelegate(delegateHandler, queue: DispatchQueue(label: "yap.camera.\(id)"))
            guard session.canAddOutput(output) else {
                throw CameraCaptureError.cannotAddOutput(id: id)
            }
            session.addOutput(output)

            delegates.append(delegateHandler)
            session.startRunning()
            sessions.append((session: session, deviceID: id))
        }
    }

    /// Get the latest frame from all configured cameras as CGImages.
    func captureAll() -> [(deviceID: String, image: CGImage)] {
        lock.lock()
        let frames = latestFrames
        lock.unlock()

        var results: [(deviceID: String, image: CGImage)] = []
        for (id, _) in sessions {
            guard let sampleBuffer = frames[id],
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { continue }
            results.append((deviceID: id, image: cgImage))
        }
        return results
    }

    /// Stop all capture sessions.
    func stop() {
        for (session, _) in sessions {
            session.stopRunning()
        }
    }

    private func updateFrame(deviceID: String, sampleBuffer: CMSampleBuffer) {
        lock.lock()
        latestFrames[deviceID] = sampleBuffer
        lock.unlock()
    }
}

// MARK: - FrameDelegate

private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let deviceID: String
    let handler: (String, CMSampleBuffer) -> Void

    init(deviceID: String, handler: @escaping (String, CMSampleBuffer) -> Void) {
        self.deviceID = deviceID
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(deviceID, sampleBuffer)
    }
}

// MARK: - CameraCaptureError

enum CameraCaptureError: Error, LocalizedError {
    case deviceNotFound(id: String, available: String)
    case cannotAddInput(id: String)
    case cannotAddOutput(id: String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id, let available):
            "Camera device not found: \(id)\nAvailable cameras:\n\(available)"
        case .cannotAddInput(let id):
            "Cannot add camera input for device: \(id)"
        case .cannotAddOutput(let id):
            "Cannot add camera output for device: \(id)"
        case .permissionDenied:
            "Camera permission is required. Grant it in System Settings > Privacy & Security > Camera."
        }
    }
}
```

- [ ] **Step 2: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/yap/CameraCapture.swift
git commit -m "feat: add CameraCapture module with AVCaptureVideoDataOutput"
```

---

### Task 3: Cameras サブコマンドの実装

**Files:**
- Create: `Sources/yap/Cameras.swift`
- Modify: `Sources/yap/Yap.swift`

- [ ] **Step 1: Cameras.swift を作成**

```swift
@preconcurrency import AVFoundation
import ArgumentParser

struct Cameras: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available cameras."
    )

    func run() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        if devices.isEmpty {
            print("No cameras found.")
            return
        }
        for device in devices {
            print("\(device.localizedName)\t\(device.uniqueID)")
        }
    }
}
```

- [ ] **Step 2: Yap.swift に Cameras を追加**

`subcommands` 配列に `Cameras.self` を追加:

```swift
subcommands: [
    Transcribe.self,
    Listen.self,
    Dictate.self,
    ListenAndDictate.self,
    MCP_Command.self,
    Cameras.self,
],
```

- [ ] **Step 3: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 4: 動作確認**

Run: `swift run --disable-sandbox yap cameras`
Expected: 接続中のカメラ一覧が表示される

- [ ] **Step 5: Commit**

```bash
git add Sources/yap/Cameras.swift Sources/yap/Yap.swift
git commit -m "feat: add 'yap cameras' subcommand to list available cameras"
```

---

### Task 4: Dictate に --camera オプションを追加してカメラキャプチャを統合

**Files:**
- Modify: `Sources/yap/Dictate.swift`

- [ ] **Step 1: --camera オプションを追加**

`Dictate` struct 内の `mlxModel` オプションの後に追加:

```swift
@Option(
    name: .long,
    help: "Camera device ID to capture. Use 'yap cameras' to list available devices. Can be specified multiple times."
) var camera: [String] = []
```

- [ ] **Step 2: run() 内でカメラ権限チェックと初期化を追加**

`run()` 内、既存の権限チェック（`AXIsProcessTrusted()` / `SCShareableContent` の後、line 113 付近）にカメラ権限チェックを追加:

```swift
if !camera.isEmpty {
    let granted = await AVCaptureDevice.requestAccess(for: .video)
    guard granted else {
        throw CameraCaptureError.permissionDenied
    }
}
```

`let screenCapture = ...` の直後（line 238 付近）にカメラ初期化を追加:

```swift
let cameraCapture: CameraCapture? = if !camera.isEmpty {
    try CameraCapture(deviceIDs: camera)
} else {
    nil
}
```

- [ ] **Step 3: スクリーンキャプチャ呼び出し箇所でカメラもキャプチャ**

`Dictate.swift` のキャプチャ箇所（txt format の場合、line 291-306 付近）を修正。スクリーンキャプチャの後にカメラキャプチャと保存を追加:

```swift
if now.timeIntervalSince(lastResultTime) > 1.5 {
    let captureStart = ContinuousClock.now
    var capturedScreenContext: ScreenContext
    if useScreenshots {
        capturedScreenContext = (try? await screenCapture.captureWithScreenshots()) ?? emptyContext
    } else {
        capturedScreenContext = (try? await screenCapture.capture()) ?? emptyContext
    }
    // Camera capture
    if let cameraCapture {
        let cameraImages = cameraCapture.captureAll()
        let dir = capturedScreenContext.displays.first?.screenshotPath
            .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? NSTemporaryDirectory() + "yap/"
        var cameraContexts: [CameraContext] = []
        for (index, cam) in cameraImages.enumerated() {
            let path = dir + "/camera-\(index).png"
            if let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
            ) {
                // Resize to max 1280px
                let scale = min(1.0, 1280.0 / Double(cam.image.width))
                let newWidth = Int(Double(cam.image.width) * scale)
                let newHeight = Int(Double(cam.image.height) * scale)
                let colorSpace = cam.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(
                    data: nil, width: newWidth, height: newHeight,
                    bitsPerComponent: cam.image.bitsPerComponent,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: cam.image.alphaInfo.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cam.image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
                    if let resized = ctx.makeImage() {
                        CGImageDestinationAddImage(dest, resized, nil)
                    } else {
                        CGImageDestinationAddImage(dest, cam.image, nil)
                    }
                } else {
                    CGImageDestinationAddImage(dest, cam.image, nil)
                }
                if CGImageDestinationFinalize(dest) {
                    cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: path))
                } else {
                    cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: nil))
                }
            }
        }
        capturedScreenContext = ScreenContext(
            displays: capturedScreenContext.displays,
            cameras: cameraContexts,
            timestamp: capturedScreenContext.timestamp
        )
    }
    screenContext = capturedScreenContext
    if showDebug {
        let elapsed = ContinuousClock.now - captureStart
        print("[context-aware] Screen capture took \(elapsed)")
        fflush(stdout)
        logScreenContext(screenContext)
    }
} else {
    screenContext = emptyContext
}
```

- [ ] **Step 4: non-txt format のキャプチャ箇所にも同様の変更を適用**

non-txt format のキャプチャ箇所（line 367-380 付近）を修正。`currentContext` 変数を使う点が異なる:

```swift
if now.timeIntervalSince(lastResultTime) > 1.5 {
    let captureStart = ContinuousClock.now
    if useScreenshots {
        currentContext = (try? await screenCapture.captureWithScreenshots()) ?? currentContext
    } else {
        currentContext = (try? await screenCapture.capture()) ?? currentContext
    }
    // Camera capture
    if let cameraCapture {
        let cameraImages = cameraCapture.captureAll()
        let dir = currentContext.displays.first?.screenshotPath
            .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? NSTemporaryDirectory() + "yap/"
        var cameraContexts: [CameraContext] = []
        for (index, cam) in cameraImages.enumerated() {
            let path = dir + "/camera-\(index).png"
            if let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
            ) {
                let scale = min(1.0, 1280.0 / Double(cam.image.width))
                let newWidth = Int(Double(cam.image.width) * scale)
                let newHeight = Int(Double(cam.image.height) * scale)
                let colorSpace = cam.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(
                    data: nil, width: newWidth, height: newHeight,
                    bitsPerComponent: cam.image.bitsPerComponent,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: cam.image.alphaInfo.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cam.image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
                    if let resized = ctx.makeImage() {
                        CGImageDestinationAddImage(dest, resized, nil)
                    } else {
                        CGImageDestinationAddImage(dest, cam.image, nil)
                    }
                } else {
                    CGImageDestinationAddImage(dest, cam.image, nil)
                }
                if CGImageDestinationFinalize(dest) {
                    cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: path))
                } else {
                    cameraContexts.append(CameraContext(deviceID: cam.deviceID, imagePath: nil))
                }
            }
        }
        currentContext = ScreenContext(
            displays: currentContext.displays,
            cameras: cameraContexts,
            timestamp: currentContext.timestamp
        )
    }
    if showDebug {
        let elapsed = ContinuousClock.now - captureStart
        print("[context-aware] Screen capture took \(elapsed)")
        fflush(stdout)
        logScreenContext(currentContext)
    }
}
```

- [ ] **Step 5: nonisolated(unsafe) 参照と SIGINT ハンドラ**

`nonisolated(unsafe) let muteCaptureRef = capture` の近くに追加:

```swift
nonisolated(unsafe) let cameraCaptureRef = cameraCapture
```

SIGINT ハンドラの `Task.detached` 内で `capture.stop()` の後に追加:

```swift
cameraCaptureRef?.stop()
```

- [ ] **Step 6: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 7: Commit**

```bash
git add Sources/yap/Dictate.swift
git commit -m "feat: add --camera option to dictate and integrate camera capture"
```

---

### Task 5: ClaudeCorrector にカメラ画像を追加

**Files:**
- Modify: `Sources/yap/ClaudeCorrector.swift:86-104`

- [ ] **Step 1: プロンプト構築にカメラ画像を追加**

`correct()` メソッド内のプロンプト構築で、display ループの後に追加:

```swift
for camera in context.cameras {
    prompt += "### Camera\n"
    if let path = camera.imagePath {
        prompt += "Photo (read this file): \(path)\n"
    }
    prompt += "\n"
}
```

- [ ] **Step 2: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/yap/ClaudeCorrector.swift
git commit -m "feat: include camera images in Claude corrector prompt"
```

---

### Task 6: MLXCorrector にカメラ画像を追加

**Files:**
- Modify: `Sources/yap/MLXCorrector.swift:43-46`

- [ ] **Step 1: images 配列にカメラ画像を追加**

`correct()` メソッド内の images 構築を修正:

```swift
var images: [UserInput.Image] = context.displays.compactMap { display in
    guard let path = display.screenshotPath else { return nil }
    return .url(URL(fileURLWithPath: path))
}
for camera in context.cameras {
    if let path = camera.imagePath {
        images.append(.url(URL(fileURLWithPath: path)))
    }
}
```

- [ ] **Step 2: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/yap/MLXCorrector.swift
git commit -m "feat: include camera images in MLX corrector"
```

---

### Task 7: デバッグログにカメラ情報を追加

**Files:**
- Modify: `Sources/yap/Dictate.swift:480-510`

- [ ] **Step 1: logScreenContext にカメラ情報を追加**

`logScreenContext()` 関数の display ループの後に追加:

```swift
for (i, camera) in context.cameras.enumerated() {
    lines.append("  Camera \(i + 1) (ID: \(camera.deviceID)):")
    if let path = camera.imagePath {
        lines.append("    Photo: \(path)")
    }
}
```

- [ ] **Step 2: ビルド確認**

Run: `swift build --disable-sandbox 2>&1 | tail -5`
Expected: Build Succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/yap/Dictate.swift
git commit -m "feat: add camera info to debug logging"
```

---

### Task 8: 動作確認

- [ ] **Step 1: cameras サブコマンド確認**

Run: `swift run --disable-sandbox yap cameras`
Expected: カメラ一覧が表示される

- [ ] **Step 2: --camera 付き dictate の動作確認（存在しないID）**

Run: `swift run --disable-sandbox yap dictate --context-aware claude --camera invalid-id 2>&1`
Expected: エラーメッセージと利用可能なカメラ一覧が表示される

- [ ] **Step 3: --camera 付き dictate の動作確認（実際のカメラ）**

実際のカメラ ID を使って `--debug` 付きで実行し、カメラ画像が保存・ログ出力されることを確認:

Run: `swift run --disable-sandbox yap dictate --context-aware claude --camera <actual-id> --debug`

- [ ] **Step 4: カメラなし dictate の regression 確認**

Run: `swift run --disable-sandbox yap dictate --context-aware claude --debug`
Expected: 既存動作に影響なし（カメラログなし）
