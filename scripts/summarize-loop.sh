#!/bin/bash
# yap context の出力を apfel で継続的にサマライズするループ
# Usage: ./scripts/summarize-loop.sh <data-dir>
# Example: ./scripts/summarize-loop.sh ~/.local/share/yap

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${1:-$SCRIPT_DIR/../tmp}"
NOTCHBAR_CLI="$HOME/ghq/github.com/azu/notchbar/.build/arm64-apple-macosx/debug/notchbar-cli"
INTERVAL=15  # 秒

SUMMARIZE_PROMPT='ウィンドウタイトルを20文字以内の日本語で要約せよ。1行のみ。説明不要。鉤括弧不要。
例: Signalsのpush-pullアルゴリズム / npm workspaceの入門 / finnvoor/yap'

INTEREST_PROMPT='入力のトピックについて、後で調べ直す価値があるか判定する。
出力は "★" か "-" の1文字のみ。他は一切出力しない。
★の条件: 具体的な技術名・ツール名・手法名・製品名が含まれている
-の条件: 動画視聴、旅行記、日記、SNS、マイページ、ホーム、タイムライン、あとで見る、検索結果、通知、設定、受信トレイ、メール一覧、一般ニュース、曖昧な内容、具体名なし、UIナビゲーション
迷ったら - にする。'

INTERESTS_FILE="$DATA_DIR/interests.ndjson"
RESEARCH_DIR="$DATA_DIR/docs/research"
mkdir -p "$RESEARCH_DIR"
PREV_CONTEXT=""

# 終了時にバックグラウンドジョブをクリーンアップ
cleanup() {
  kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ★トピックをclaude -pでdeep researchしてファイルに保存
research_topic() {
  local topic="$1" url="$2" timestamp="$3"

  local index_file="$RESEARCH_DIR/index.ndjson"

  # URLベースのロック（同じURLの並行調査を防止）
  local lock_id=$(echo "${url:-$topic}" | md5 | head -c 12)
  local lockfile="$RESEARCH_DIR/.lock_${lock_id}"
  if [ -f "$lockfile" ]; then
    echo "  ⏭ 調査中: $topic"
    return
  fi
  touch "$lockfile"
  trap "rm -f '$lockfile'" RETURN

  # 調査開始をインデックスに仮登録（topic_idはまだ未定なのでlock_idで仮置き）
  jq -n -c --arg topic_id "pending:${lock_id}" --arg topic "$topic" --arg url "$url" \
    --arg status "in_progress" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{time: $time, topic_id: $topic_id, topic: $topic, url: $url, status: $status}' >> "$index_file"

  # 既存topic_idリストをインデックスから取得
  local existing_ids=$(jq -r '.topic_id' "$index_file" 2>/dev/null | grep -v '^pending:' | sort -u | tr '\n' ', ')

  local prompt="ユーザーが「$topic」を閲覧していた。"
  [ -n "$url" ] && prompt="$prompt
URL: $url (fetchして内容を把握すること)"
  prompt="$prompt

## Step 1: topic_idの決定と重複チェック

このトピックにtopic_idを付与せよ（小文字、ハイフン区切り、2-4語。例: esbuild-v028, push-pull-signals）。
同じ大きな主題は同じtopic_idにする。

既にリサーチ済みのtopic_id一覧: [${existing_ids:-なし}]

もしこのトピックが既存topic_idと同じ主題なら、1行目に「SKIP: {topic_id}」とだけ出力して終了せよ。

## Step 2: リサーチ（重複でない場合のみ）

目的: この記事/ページの要約ではなく、ユーザーがまだ知らない関連情報を探してくる。

検索の方針:
- 閲覧URLと同じ情報は不要。別の視点・別のソースを探す
- 最新の展開（アップデート、議論）を優先
- 実践的な情報（ベンチマーク、移行事例、比較）を優先
- 一次情報（公式ドキュメント、RFC、リポジトリ）を優先
- 2-3回WebSearchし、有用な情報を2-5件見つける

出力形式（日本語、断定形、事実ベース、各文100文字以内）:
topic_id: {決定したtopic_id}

# $topic

きっかけ: [$topic]($url)

[見つけた情報のタイトル](URL)
説明文。1-2文で事実を書く。

[見つけた情報のタイトル](URL)
説明文。

(2-5件繰り返す)"

  echo "  🔍 リサーチ開始: $topic"
  local tmpfile=$(mktemp)
  echo "$prompt" | env -u CMUX_SOCKET -u CMUX_PANEL_ID -u CMUX_PORT -u CMUX_BUNDLE_ID claude -p \
    --model sonnet \
    --tools "Read,WebFetch,WebSearch" \
    --allowedTools "Read,WebFetch,WebSearch" \
    --setting-sources "" \
    --settings "$SCRIPT_DIR/research-settings.json" \
    --strict-mcp-config \
    --mcp-config '{"mcpServers":{}}' \
    --disable-slash-commands \
    --dangerously-skip-permissions \
    --no-session-persistence \
    --max-budget-usd 0.50 \
    > "$tmpfile" 2>"$RESEARCH_DIR/last-error.log" || true

  if [ ! -s "$tmpfile" ]; then
    rm -f "$tmpfile"
    echo "  ⚠ リサーチ失敗: $topic"
    return
  fi

  # SKIP判定チェック
  local first_line=$(head -1 "$tmpfile")
  if [[ "$first_line" == SKIP:* ]]; then
    local skip_id=$(echo "$first_line" | sed 's/SKIP: *//')
    echo "  ⏭ 重複スキップ (topic_id: $skip_id): $topic"
    rm -f "$tmpfile"
    return
  fi

  # topic_idを抽出してファイル名に使用
  local topic_id=$(grep -oE '^topic_id: [a-z0-9-]+' "$tmpfile" | head -1 | sed 's/topic_id: //')
  [ -z "$topic_id" ] && topic_id="unknown"
  local outfile="$RESEARCH_DIR/${timestamp}_${topic_id}.md"
  mv "$tmpfile" "$outfile"

  echo "  📄 リサーチ完了 ($topic_id): $outfile"
  # インデックスのpending行を正式なtopic_idで上書き
  jq -n -c --arg topic_id "$topic_id" --arg topic "$topic" --arg url "$url" \
    --arg file "$(basename "$outfile")" --arg status "done" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{time: $time, topic_id: $topic_id, topic: $topic, url: $url, file: $file, status: $status}' >> "$index_file"
  # リサーチ結果から見つけた情報をnotchに通知
  local fullpath=$(cd "$(dirname "$outfile")" && pwd)/$(basename "$outfile")
  # きっかけ行の次のリンクタイトルを抽出
  local finding=$(grep -oE '\[.+?\]\(.+?\)' "$outfile" | grep -v 'きっかけ' | head -1 | sed 's/\[//;s/\](.*)//')
  local notch_msg="${finding:-$topic}"
  "$NOTCHBAR_CLI" --id "yap-research" --expand 5 "[🔍 ${notch_msg}](${fullpath})" 2>/dev/null || true
}

while true; do
  context=$(.build/arm64-apple-macosx/release/yap context --data-dir "$DATA_DIR" --last 1m 2>/dev/null \
    | jq -c 'select(.type == "screenshot" and .is_focused == true)' || true)
  if [ -n "$context" ] && [ "$context" != "$PREV_CONTEXT" ]; then
    PREV_CONTEXT="$context"

    # 最後のレコードからapp/title/url/idle_secondsを取得
    last_record=$(echo "$context" | tail -1)
    app=$(echo "$last_record" | jq -r '.app // empty')
    title=$(echo "$last_record" | jq -r '.title // empty')
    url=$(echo "$last_record" | jq -r '.url // empty')
    idle=$(echo "$last_record" | jq -r '.idle_seconds // 0')

    # 離席判定（60秒以上操作なし）
    if [ "$(echo "$idle > 60" | bc 2>/dev/null)" = "1" ]; then
      echo "--- $(date '+%H:%M:%S') --- (離席中: ${idle}s)"
      sleep "$INTERVAL"
      continue
    fi

    if [ -n "$title" ]; then
      # 40文字以下ならそのまま、長ければLLMで要約
      if [ "${#title}" -le 40 ]; then
        topic="$title"
      else
        topic=$(echo "$title" | apfel -s "$SUMMARIZE_PROMPT" "要約:" 2>/dev/null || true)
        topic=$(echo "$topic" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/[「」""\""]//g')
        [ -z "$topic" ] && topic="$title"
      fi
      summary="$app: $topic"
    else
      topic=""
      summary="$app"
    fi

    echo "--- $(date '+%H:%M:%S') ---"
    echo "$summary"

    # 興味判定不要なパターン（LLMスキップ → 自動 -）
    SKIP_TITLE='^(\([0-9]+\) )?(ホーム|通知|受信トレイ|マイページ|タイムライン|あとで見る|設定|検索|新しいタブ|Members|Claude)( /| •| -|$)|Slack$|（チャンネル）|^[0-9]{8}-[0-9]{6}_|localhost:'
    # ターミナルアプリはURLがないのでリサーチ対象外
    TERMINAL_APPS='cmux|Terminal|iTerm2|Ghostty|Alacritty|WezTerm|kitty'

    # トピックがある場合のみ興味判定
    skip=false
    if [ -z "$topic" ]; then skip=true; fi
    if echo "$topic" | grep -qE "$SKIP_TITLE"; then skip=true; fi
    if echo "$app" | grep -qE "^($TERMINAL_APPS)$"; then skip=true; fi

    if [ "$skip" = false ]; then
      interest=$(echo "$summary" | apfel -s "$INTEREST_PROMPT" "判定:" 2>/dev/null || true)
      interest_trimmed=$(echo "$interest" | head -1 | tr -d '[:space:]')
      if [[ "$interest_trimmed" == ★* ]]; then
        echo "  ★ $topic"
        local_time=$(date '+%Y%m%d-%H%M%S')
        topic_id=$(echo "${url:-$topic}" | md5 | head -c 12)
        jq -n -c --arg topic "$topic" --arg summary "$summary" --arg url "$url" \
          --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg topic_id "$topic_id" \
          '{time: $time, topic_id: $topic_id, topic: $topic, summary: $summary, url: $url}' >> "$INTERESTS_FILE"
        "$NOTCHBAR_CLI" --id "yap-interest" "★ $topic" 2>/dev/null || true
        # バックグラウンドでdeep research
        ( set +eu; research_topic "$topic" "$url" "$local_time" ) &
      else
        echo "  -"
        "$NOTCHBAR_CLI" --id "yap-summary" "$summary" 2>/dev/null || true
      fi
    else
      "$NOTCHBAR_CLI" --id "yap-summary" "$summary" 2>/dev/null || true
    fi
    echo
  fi
  sleep "$INTERVAL"
done
