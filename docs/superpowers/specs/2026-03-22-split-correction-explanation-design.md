# Split Correction and Context Explanation

## Overview

テキスト補正とコンテキスト解説を別々の LLM 呼び出しに分離する。補正は高速な小さいモデル（local/haiku）、解説は画像理解が得意なモデル（mlx/claude）で行う。

## Options

```
--context-aware local|claude|mlx       # テキスト補正（既存）
--context-explain mlx|claude           # コンテキスト解説（新規、省略可）
--context-explain-interval <seconds>   # 解説間隔。0=毎回、10=10秒ごと。デフォルト0
```

## Architecture

### Corrector の変更

- `CorrectionResult` から `activity` / `summary` を削除
- ClaudeCorrector: `--json-schema` を外し `--output-format text` に戻す。テキスト補正のみ
- MLXCorrector: `ACTIVITY:` / `SUMMARY:` パースを削除。テキスト補正のみ
- TranscriptionCorrector: 変更なし

### 新規: ContextExplainer

```swift
protocol ContextExplainer: Sendable {
    func explain(context: ScreenContext) async -> ContextExplanation?
}

struct ContextExplanation: Sendable {
    let activity: String
    let summary: String
}
```

実装:
- `ClaudeContextExplainer`: `claude -p --output-format json --json-schema` で activity/summary を返す。スクショ・カメラ画像を読み込む
- `MLXContextExplainer`: MLX VLM でスクショ・カメラ画像を入力し、`ACTIVITY:` / `SUMMARY:` 形式でパース

### 実行フロー

```
補正テキスト到着
  ├── [同期] corrector.correct(text, context) → 補正テキスト即出力
  └── [並行] explainer.explain(context) → 解説を非同期出力（intervalスロットル）
```

補正テキストの出力は解説を待たない。解説は来た順に出力。

### 出力フォーマット

NDJSON:
```jsonl
{"type":"transcription","text":"パセリの残量はどれぐらい。","start":1.2,"end":3.5}
{"type":"context","activity":"cooking","summary":"キッチンで食材を確認中"}
```

txt:
```
パセリの残量はどれぐらい。
activity: cooking / summary: キッチンで食材を確認中
```

`type` フィールドで transcription と context を区別する。activity/summary が nil の場合（explainer 未指定、または短いテキストでスキップ時）は context 行を出力しない。

## Modified Files

- Create: `Sources/yap/ContextExplainer.swift` — プロトコル + ClaudeContextExplainer + MLXContextExplainer
- Modify: `Sources/yap/Dictate.swift` — `--context-explain` / `--context-explain-interval` オプション追加、並行実行ロジック
- Modify: `Sources/yap/ClaudeCorrector.swift` — `--json-schema` / `--output-format json` を外してテキスト補正のみに戻す
- Modify: `Sources/yap/MLXCorrector.swift` — ACTIVITY/SUMMARY パースを削除、プロンプトをテキスト補正のみに戻す
- Modify: `Sources/yap/OutputFormat.swift` — `formatCorrectedSegment` から activity/summary パラメータ削除、NDJSON に `type` フィールド追加
- Modify: `CorrectionResult` in `Dictate.swift` — activity/summary フィールド削除

## Error Handling

- explainer の失敗は無視（補正テキストは出力される）
- explainer のタイムアウトは corrector と同じ値を使う
- explainer 未指定時は解説を出力しない（既存動作と互換）

## Out of Scope

- 補正と解説で異なるモデルの自動選択
- 解説結果の永続化
- 解説結果を補正にフィードバック
