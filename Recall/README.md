# 🧠 Recall — local screen memory

A macOS menu-bar app that passively captures your screen, extracts text with
Apple Vision OCR, stores structured memories in Supermemory Local, and lets you
search/chat over everything you've ever seen. 100% offline (Ollama for LLM).
Rewind, rebuilt on `localhost:6767`.

## The storage trick (GB → MB)

Pixels are never persisted. Every 5s: capture → 64-bit dHash dedupe (~90% of
frames dropped: static screens, idle) → Apple Vision OCR → **discard the
frame**. Kept: ~2-5 KB of text + an optional 480px HEIC thumbnail (~20 KB) for
the timeline. A full day is a few MB; a year fits in single-digit GB.

Second dedupe layer: consecutive frames from the same window with >0.95 Jaccard
text similarity merge into one memory (scrolling a document ≠ N memories).

## Pipeline

```
ScreenCaptureKit (5s, active display)
 → dHash dedupe (rolling window of 5)
 → context: frontmost app, AX window title, browser URL
 → privacy filter (app/domain blocklists, pause) — blocked frames die pre-OCR
 → Vision OCR (accurate, confidence ≥ 0.3)
 → SQLite: frames (source of truth) + pending_memories (crash-safe queue)
 → enrichment: qwen3:8b → {summary, facts, category, tags}   ← never blocks
 → supermemory local (containerTag "recall")
```

Why enrichment before ingest: supermemory's local memory agent extracts nothing
from raw UI text (0 memories → doc marked failed → invisible to search). We
ingest a first-person summary + facts; full OCR stays local in SQLite.

## Use it

- **⌥Space** — ask anything ("what was that error I saw in the terminal an
  hour ago"). Hybrid search → local LLM → streamed answer with citations.
  Time expressions ("yesterday afternoon", "2 hours ago") scope the results.
- **Menu bar 🧠** — live stats (captured/deduped/kept/blocked, dedupe rate),
  service health dots, pause (15m/1h/∞), last memory.
- **Timeline** — scrub any day, thumbnails grouped by hour, click for full OCR
  text + "Ask about this".
- **Settings** — capture interval, blocklists, retention, endpoints, launch at
  login, export-all to JSONL, forget-a-time-range (local + engine).

## Build & run

```bash
# prerequisites: supermemory-server (port 6767), ollama + qwen3:8b (11434)
cd Recall
./Scripts/make-app.sh          # swift build + .app assembly + codesign
open build/Recall.app
```

Grant Screen Recording + Accessibility on first run (onboarding walks through
it). **Signing note:** the script signs with your Apple Development certificate
so TCC permissions survive rebuilds — ad-hoc signing breaks Screen Recording on
every build (learned the hard way). If permissions show granted but capture is
dead, the TCC entry is stale: `tccutil reset ScreenCapture dev.shivam.recall`
and re-grant.

Data: `~/Library/Application Support/Recall/` (SQLite + thumbs).

## Privacy

Blocklisted apps/domains (password managers, banking by default) are discarded
before OCR — never queued, never stored. Pause anytime from the menu. Nothing
ever leaves the machine; the only network calls are to localhost.
