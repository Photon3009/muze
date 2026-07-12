#!/bin/zsh
# Boot the whole Constellation stack: Ollama → Supermemory Local → Constellation.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! curl -s -m 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
  echo "→ starting ollama"
  nohup ollama serve > /tmp/constellation-ollama.log 2>&1 &
  until curl -s -m 2 http://localhost:11434/api/tags > /dev/null 2>&1; do sleep 1; done
fi

if ! curl -s -m 2 http://localhost:6767/ > /dev/null 2>&1; then
  echo "→ starting supermemory local"
  (cd "$ROOT" && nohup "$HOME/.local/bin/supermemory-server" > /tmp/constellation-engine.log 2>&1 &)
  until curl -s -m 2 http://localhost:6767/ > /dev/null 2>&1; do sleep 1; done
fi

if ! curl -s -m 2 http://localhost:7777/api/health > /dev/null 2>&1; then
  echo "→ starting constellation"
  (cd "$ROOT" && nohup node server/index.js > /tmp/constellation-server.log 2>&1 &)
  until curl -s -m 2 http://localhost:7777/api/health > /dev/null 2>&1; do sleep 1; done
fi

echo "✦ Constellation is up → http://localhost:7777"
open http://localhost:7777
