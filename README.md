# 🗣️ yap

A CLI for on-device speech transcription using [Speech.framework](https://developer.apple.com/documentation/speech) on macOS 26.

![Demo](https://github.com/user-attachments/assets/326de51d-5a58-4c96-9d6c-98b07e6d9e58)

### Usage

```
USAGE: yap transcribe [--locale <locale>] [--censor] <input-file> [--txt] [--srt] [--vtt] [--json] [--output-file <output-file>] [--max-length <max-length>] [--word-timestamps]

ARGUMENTS:
  <input-file>            Path to an audio or video file to transcribe.

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -o, --output-file <output-file>
                          Path to save the transcription output. If not provided,
                          output will be printed to stdout.
  -m, --max-length <max-length>
                          Maximum sentence length in characters. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

### Installation

#### Homebrew

```bash
brew install yap
```

#### Mint

```bash
mint install finnvoor/yap
```

### Examples

#### Transcribe a YouTube video using yap and [yt-dlp](https://github.com/yt-dlp/yt-dlp)

```bash
yt-dlp "https://www.youtube.com/watch?v=ydejkIvyrJA" -x --exec yap
```

#### Summarize a video using yap and [llm](https://llm.datasette.io/en/stable)

```bash
yap video.mp4 | uvx llm -m mlx-community/Llama-3.2-1B-Instruct-4bit 'Summarize this transcript:'
```

#### Create SRT captions for a video

```bash
yap video.mp4 --srt -o captions.srt
```

#### Generate WebVTT subtitles

```bash
yap video.mp4 --vtt -o subtitles.vtt
```

#### Export JSON with word-level timestamps

```bash
yap video.mp4 --json --word-timestamps -o transcript.json
```

### Live System Audio

`yap listen` transcribes system audio in real time — anything playing on your computer.

```
USAGE: yap listen [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Screen Recording permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording.

#### Examples

```bash
# Transcribe system audio live
yap listen

# Pipe live transcription to another tool
yap listen | uvx llm 'Translate this to French:'

# Save system audio as VTT subtitles
yap listen --vtt > captions.vtt
```

### Listen and Dictate

`yap listen-and-dictate` transcribes both system audio and microphone input simultaneously — perfect for meeting transcription.

```
USAGE: yap listen-and-dictate [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--mic-label <mic-label>] [--system-label <system-label>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --mic-label <mic-label> Speaker label for microphone audio in timed output
                          formats. (default: Mic)
  --system-label <system-label>
                          Speaker label for system audio in timed output
                          formats. (default: System)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Both Screen Recording and Microphone permissions are required. Grant them to your terminal app in System Settings > Privacy & Security.

#### Examples

```bash
# Transcribe a video call (both sides)
yap listen-and-dictate

# Save a meeting transcript
yap listen-and-dictate > meeting.txt

# Save a meeting transcript as VTT with speaker labels
yap listen-and-dictate --vtt > meeting.vtt

# Use custom speaker labels
yap listen-and-dictate --vtt --mic-label Alice --system-label Bob > meeting.vtt
```

### Dictation

`yap dictate` transcribes microphone input in real time.

```
USAGE: yap dictate [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone.

#### Examples

```bash
# Dictate from your microphone
yap dictate

# Dictate and save to a file
yap dictate > notes.txt
```

### Context-Aware Dictation

`yap dictate --context-aware` uses screen context (screenshots, window titles, URLs) to correct transcription with an LLM. Three backends are available:

| Backend | Flag | Model | Image Input | Cost |
|---------|------|-------|-------------|------|
| local | `--context-aware local` | Apple FoundationModels (~3B) | No (OCR text) | Free |
| claude | `--context-aware claude` | Claude via `claude -p` | Yes (screenshots) | API |
| mlx | `--context-aware mlx` | MLX VLM (Qwen2.5-VL etc.) | Yes (screenshots) | Free |

```
OPTIONS:
  --context-aware <backend>  Backend: local, claude, or mlx
  --debug                    Print screen context and correction status to stdout
  --claude-model <model>     Model for claude backend (default: haiku)
  --mlx-model <model-id>     MLX model ID from Hugging Face
  --ignore-titles <keywords> Comma-separated keywords for media site detection
  --txt/--srt/--vtt/--json/--ndjson
                             Output format (default: --txt)
```

> Screen Recording and Accessibility permissions are required. Grant them in System Settings > Privacy & Security.

#### Features

- Multi-display support (screenshots + window info per display)
- Browser URL extraction (Firefox, Safari, Chrome, Arc, etc.)
- Media playback detection: mutes mic when video/music is playing (NowPlaying API)
- NDJSON output for streaming to other tools

#### Examples

```bash
# On-device correction with FoundationModels
yap dictate --context-aware local

# Correction with Claude (default: haiku)
yap dictate --context-aware claude

# Correction with Claude Sonnet
yap dictate --context-aware claude --claude-model sonnet

# On-device correction with MLX VLM
yap dictate --context-aware mlx

# Use a different MLX model
yap dictate --context-aware mlx --mlx-model mlx-community/Qwen3-VL-4B-Instruct-4bit

# Debug mode (shows screen context, correction status, timing)
yap dictate --context-aware mlx --debug

# NDJSON output for piping
yap dictate --context-aware claude --ndjson
```

#### MLX Model Cache

MLX models are downloaded from Hugging Face on first use and cached at:

```
~/Library/Caches/models/mlx-community/
```

To remove cached models:

```bash
rm -rf ~/Library/Caches/models/mlx-community/<model-name>
```

#### Building with MLX

`swift build` requires Metal shaders to be compiled separately:

```bash
# 1. Install Metal Toolchain (if needed)
xcodebuild -downloadComponent MetalToolchain

# 2. Build
swift build --disable-sandbox -c release

# 3. Compile Metal shaders
METAL_DIR=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
INCLUDE_DIR=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated"
for f in $(find "$METAL_DIR" -name "*.metal"); do
    xcrun metal -c "$f" -I "$INCLUDE_DIR" -o "/tmp/mlx_$(basename "$f" .metal).air"
done
xcrun metallib /tmp/mlx_*.air -o .build/release/mlx.metallib
```

### MCP Server

yap includes an [MCP](https://modelcontextprotocol.io) server that exposes a `transcribe` tool, allowing any MCP-compatible agent to transcribe audio and video files.

#### Claude Code

```bash
claude mcp add yap -- yap mcp
```

#### Codex

```bash
codex mcp add yap -- yap mcp
```
