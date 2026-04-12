# OCR (Vision VNRecognizeTextRequest) 削除の経緯

## 背景

`yap capture` は定期的にスクリーンショットを撮影し、Vision フレームワークの `VNRecognizeTextRequest` (.accurate) で画面上のテキストを OCR していた。

## 問題

OCR 処理が CPU を大量に消費していた。ベンチマーク結果:

| 項目 | .fast | .accurate |
|---|---|---|
| 処理時間 (1470x956) | 0.045s | 2.012s |
| 日本語認識行数 | 0行 | 89行 |
| CPU 倍率 | - | 44.5x |

- `.accurate` は1回あたり約2秒、CPU 200%近く消費
- `--interval 10` だと10秒ごとに2秒間CPUを占有
- `.fast` は日本語をほぼ認識できず代替にならない
- 解像度を下げても改善しない（75%で一致率37%、50%で1%）
- mute 状態でもOCRは独立して動くため、常にCPUを消費

## 判断

- OCR テキストの主な用途は dedup のハッシュ比較とコンテキストファイル保存
- AX ツリー（アプリ名、ウィンドウタイトル、URL）で十分なコンテキストが取得できる
- OCR を無効化（`--no-ocr`）して確認したところ、CPU 消費がほぼなくなった
- 機能に対してコストが見合わないため削除

## 削除内容

- `performOCR()` 関数
- `VNRecognizeTextRequest` / Vision フレームワーク依存
- `DisplayContext.ocrText` フィールド
- OCR テキストの `.txt` ファイル保存
- dedup における OCR ハッシュ比較
- `ScreenContextCapture.captureWithScreenshots()` (OCR有無の分岐が不要になったため)

## 日付

2026-03-29
