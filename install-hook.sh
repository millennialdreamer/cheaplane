#!/usr/bin/env bash
# Cheaplane — one-shot installer for the "use delegate" reminder hook.
#
# Registers hooks/delegate-reminder.sh as a Claude Code UserPromptSubmit hook, so
# your agent is reminded to use `delegate` on every turn. An *installed* tool isn't
# a *used* tool until something keeps the habit fresh — this is that something.
#
# Safe & idempotent:
#   - backs up your settings.json before touching it
#   - MERGES into existing hooks (never overwrites what you already have)
#   - de-dupes by script name, so re-running (or moving the repo) never piles up
#   - writes atomically (temp file + validate + rename)
#
# Usage:   bash install-hook.sh
# Target:  $HOME/.claude/settings.json   (override with CLAUDE_SETTINGS=/path)
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/hooks/delegate-reminder.sh"
[ -f "$HOOK" ] || { echo "error: hook not found at $HOOK"; exit 1; }
chmod +x "$HOOK"

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

HOOK_PATH="$HOOK" SETTINGS_PATH="$SETTINGS" python3 <<'PY'
import json, os, shutil, time

settings = os.environ["SETTINGS_PATH"]
hook = os.environ["HOOK_PATH"]
parent = os.path.dirname(settings)
if parent:
    os.makedirs(parent, exist_ok=True)

try:
    with open(settings) as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}

ups = data.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])

def is_ours(h):
    cmd = h.get("command")
    return isinstance(cmd, str) and os.path.basename(cmd) == "delegate-reminder.sh"

# Idempotent by SCRIPT, not just by path: if the only delegate-reminder entry is
# already this exact path, do nothing; otherwise rebuild cleanly (handles a moved
# or re-cloned repo without leaving a duplicate or a dead path behind).
existing = [h for entry in ups for h in entry.get("hooks", []) if is_ours(h)]
if len(existing) == 1 and existing[0].get("command") == hook:
    print("✓ already installed — nothing to do.")
else:
    if os.path.exists(settings):
        bak = settings + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(settings, bak)
        print("backed up settings →", bak)
    # Drop any prior delegate-reminder entry (dedupe / fix a moved repo path)...
    for entry in ups:
        entry["hooks"] = [h for h in entry.get("hooks", []) if not is_ours(h)]
    ups[:] = [e for e in ups if e.get("hooks")]
    # ...then register exactly one pointing at the current location.
    ups.append({"hooks": [{"type": "command", "command": hook}]})
    tmp = settings + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    with open(tmp) as f:        # validate the temp file before swapping it in
        json.load(f)
    os.replace(tmp, settings)
    print("✓ installed delegate reminder hook →", settings)
    print("  start a new Claude Code session for it to take effect.")
PY
