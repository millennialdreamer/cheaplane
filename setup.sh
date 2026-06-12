#!/usr/bin/env bash
# Cheaplane — one-command setup for Claude Code.
# Wires the `delegate` tool + the reminder hook into Claude Code, end to end.
# Safe to re-run: every step is idempotent.
#
#   bash setup.sh
#
# Prereq: a cheap-model proxy on http://localhost:4000 (see step 2 / litellm.yaml.example).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

echo "▸ 1/4  Python deps"
if command -v uv >/dev/null 2>&1; then
  uv sync >/dev/null
  PYBIN="$ROOT/.venv/bin/python"
else
  [ -d .venv ] || python3 -m venv .venv
  .venv/bin/pip install -q mcp
  PYBIN="$ROOT/.venv/bin/python"
fi
echo "  ✓ $PYBIN"

BASE="${DELEGATE_BASE_URL:-http://localhost:4000}"
echo "▸ 2/4  cheap-model proxy at $BASE"
if curl -sf --max-time 3 "$BASE/health/liveliness" >/dev/null 2>&1 || curl -sf --max-time 3 "$BASE/v1/models" >/dev/null 2>&1; then
  echo "  ✓ proxy is up"
else
  echo "  ! no proxy yet — start one in 3 steps:"
  echo "      cp litellm.yaml.example litellm.yaml"
  echo "      export DEEPSEEK_API_KEY=sk-..."
  echo "      litellm --config litellm.yaml"
fi

echo "▸ 3/4  register the MCP server with Claude Code"
if command -v claude >/dev/null 2>&1; then
  if claude mcp list 2>/dev/null | grep -qi '\bdelegate\b'; then
    echo "  • 'delegate' already registered — skipping"
  else
    claude mcp add delegate -s user -- "$PYBIN" "$ROOT/server.py" \
      && echo "  ✓ registered (user scope)" \
      || echo "  • couldn't auto-register — add it manually (README → Quick start)"
  fi
else
  echo "  • Claude Code CLI not found — register manually (README → Quick start)"
fi

echo "▸ 4/4  install the 'use delegate' reminder hook"
bash install-hook.sh

echo "▸ verify end-to-end"
# a just-started proxy needs a moment — wait up to ~10s for it before probing
for _ in $(seq 1 10); do
  if curl -sf --max-time 2 "$BASE/health/liveliness" >/dev/null 2>&1 || curl -sf --max-time 2 "$BASE/v1/models" >/dev/null 2>&1; then break; fi
  sleep 1
done
"$PYBIN" probe.py || echo "  (probe failed — is the proxy at $BASE up? see step 2)"

echo "✓ done — start a NEW Claude Code session and your agent will offload grunt work to cheap models."
