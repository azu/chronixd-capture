# Structured Context Output for Claude Corrector

## Overview

Claude バックエンドの補正結果に活動ログ情報（activity, summary）を追加する。`--json-schema` を使って構造化出力を強制し、NDJSON 出力にコンテキスト情報を含める。

## Requirements

- `claude -p` に `--json-schema` と `--output-format json` を渡して構造化出力を得る
- 補正テキストに加えて `activity`（何をしているか）と `summary`（状況の1行サマリー）を返す
- NDJSON 出力時にこれらのフィールドを含める
- `--context-aware local` / `mlx` や短いテキスト（minCorrectionLength 未満）ではこれらのフィールドは含めない

## JSON Schema

`claude -p` に渡す schema:

```json
{
  "type": "object",
  "properties": {
    "text": { "type": "string", "description": "補正済みテキスト" },
    "activity": { "type": "string", "description": "何をしているか (例: coding, cooking, reading, browsing, meeting)" },
    "summary": { "type": "string", "description": "状況の1行サマリー" }
  },
  "required": ["text", "activity", "summary"]
}
```

## Architecture

### Modified Files

#### `CorrectionResult` (Dictate.swift)

`activity` と `summary` フィールドを追加:

```swift
struct CorrectionResult: Sendable {
    let original: String
    let corrected: String
    let status: CorrectionStatus
    let activity: String?
    let summary: String?
}
```

#### `ClaudeCorrector.swift`

- `--output-format text` → `--output-format json`
- `--json-schema '{...}'` を引数に追加
- レスポンスの JSON をパースし、`text`, `activity`, `summary` を抽出
- JSON パース失敗時はレスポンス全体をテキストとして扱う（フォールバック）

#### `TranscriptionCorrector.swift` / `MLXCorrector.swift`

`CorrectionResult` 初期化に `activity: nil, summary: nil` を渡す。

#### NDJSON 出力フォーマット（Dictate.swift の出力処理）

`--context-aware claude` 使用時、NDJSON 出力に `activity` と `summary` を含める:

```json
{"text":"パセリの残量はどれぐらいだったかね。","start":1.2,"end":3.5,"activity":"cooking","summary":"キッチンで食材を確認中"}
```

activity/summary が nil の場合はフィールドを省略。

## Error Handling

- JSON パース失敗 → レスポンス全体を text として扱い、activity/summary は nil
- `--json-schema` が `claude` CLI でサポートされていない古いバージョン → エラーになるが、claude CLI のアップデートで対応

## Out of Scope

- local / mlx バックエンドでの構造化出力
- activity の値の正規化（フリーテキスト）
- 活動ログの永続化（stdout 出力のみ）
