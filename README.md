# ✦ Constellation

**Press one key — your laptop remembers this moment.**

A screenshot is the universal API to every app you use: VS Code, Figma, Spotify,
a PDF, a tweet. Constellation captures your laptop's current state (screenshot +
which app + window title + browser URL) into [Supermemory Local](https://supermemory.ai/docs/self-hosting/overview),
then gives the engine the interface it never had:

- **✦ Constellation** — every memory is a star; semantically related memories
  link into constellations you can fly through.
- **◉ Oracle** — ask anything; answers are synthesized by a local LLM from your
  top matching memories, with citations.
- **☄ Compass** — where your attention is going: capture rhythm, apps, drift.

Everything runs on `localhost`. Nothing ever leaves your machine — the whole
stack works with WiFi off.

## Architecture

```
hotkey / native ⌘⇧3 screenshots
        │
        ▼
Node server (:7777) ── screencapture + AppleScript context
        │                       │
        ├── Apple Vision OCR (on-device, server/ocr.jxa)
        ├── Ollama (:11434) narrates the screen as a first-person memory
        │                       │
        ▼                       ▼
Supermemory Local (:6767)   data/captures/ (PNGs + OCR sidecars for the UI)
  fact extraction · embeddings · knowledge graph
```

Token economy by design: OCR, context, embeddings, graph linking, and all stats
are done on-device by Apple Vision, the local engine, or plain code. The only
LLM calls are local Ollama: one narration per capture, and answer synthesis
over the top-6 retrieved memories per question. Zero cloud tokens, ever.

## Run it

```bash
# one-time setup
npx supermemory local            # installs supermemory-server
brew install ollama && ollama pull qwen3:8b
npm install && cd web && npm install && npm run build && cd ..

# every day
./bin/start.sh                   # boots ollama → engine → constellation, opens the UI
```

Open **http://localhost:7777**. The capture button (or `⌘⇧M` once bound, below)
captures the moment; any native macOS screenshot (`⌘⇧3` / `⌘⇧4`) is ingested
automatically by the folder watcher.

### System-wide hotkey (works in any app)

Open the **Shortcuts** app → new shortcut → add **Run Shell Script**:

```
/bin/zsh /Users/shivamverma/Development/mycreations/supermemory-masala/bin/capture.sh screen
```

Then Shortcut settings → **Add Keyboard Shortcut** → press `⌘⇧M`.
Modes: `screen` (default), `window`, `selection`.

### macOS permissions (required for real captures)

- **Screen Recording**: System Settings → Privacy & Security → Screen Recording
  → enable your terminal (or whatever runs `bin/start.sh`). Without it,
  screenshots contain only your wallpaper.
- **Automation/Accessibility**: allow your terminal to control **System Events**
  (frontmost app + window title) and your browser (URL). macOS prompts on the
  first capture.

## Config

Engine model config lives in `~/.supermemory/env` (OpenAI-compatible → Ollama):

```
OPENAI_BASE_URL=http://localhost:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen3:8b            # must be a solid native tool-caller (see below)
OPENAI_FAST_MODEL=qwen3:8b
SUPERMEMORY_DATA_DIR=<repo>/.supermemory
```

Constellation server env: `CONSTELLATION_PORT` (7777), `ORACLE_MODEL`
(qwen3:8b), `CONSTELLATION_TAG` (container tag, default `constellation`).

## Hard-won notes

- **The extraction model must be a reliable native tool-caller.** The engine's
  memory agent creates memories via tool calls. `qwen3:8b` works. `llama3.1:8b`
  narrates its tool calls as prose → 0 memories. `gpt-oss:20b` emits malformed
  tool-call JSON through Ollama (`{"key:value` — missing quote) → HTTP 500 →
  document marked failed.
- **Screenshots are ingested as narrated text, not image uploads.** The v0.0.3
  file bucket is broken (`invalid local file storage key`), and raw OCR dumps
  yield 0 memories anyway — the agent wants prose. On-device narration fixes
  both; the PNG stays local for the UI.
- Documents that produce 0 memories are marked `failed` and excluded from
  search — keep captures narrative and ~1 chunk long.
