#!/usr/bin/env bash
# prepublish_check.sh — generic pre-publish safety scan for an open-source repo.
#
# Flags, in EVERY file git will commit (this script included):
#   - real API keys (long sk-... strings; the "sk-litellm" placeholder is allowed)
#   - machine-absolute paths under your home dir
#   - author-identity leaks: any email address, or your OS username
#
# It reads your live $USER / $HOME at RUNTIME, so the script itself contains no
# private data and is safe to ship in the repo. Exit 0 = clean, 1 = found issues.
set -euo pipefail
cd "$(dirname "$0")"

# Files git would commit = tracked + untracked-but-not-ignored. Fall back to find
# (minus .venv/.git/.mcp.json) when the repo isn't initialized yet.
files=$( { git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u | grep -v '^$' || true )
[ -z "$files" ] && files=$(find . -type f -not -path './.venv/*' -not -path './.git/*' -not -name '.mcp.json' | sed 's|^\./||')

FILES="$files" python3 <<'PY'
import os, re, sys

me    = os.environ.get("USER", "")
home  = os.environ.get("HOME", "")
files = [f for f in os.environ["FILES"].splitlines() if f.strip()]

KEY  = re.compile(r"sk-[A-Za-z0-9_\-]{20,}")  # long real keys
MAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

fails = 0
for f in files:
    if not os.path.isfile(f):
        continue
    t = open(f, encoding="utf-8", errors="replace").read()
    probs = []
    keys = [k for k in KEY.findall(t) if k != "sk-litellm"]
    if keys:
        probs.append("real-key %s" % keys[:2])
    if home and home in t:
        probs.append("home-path %s" % home)
    if MAIL.search(t):
        probs.append("email %s" % MAIL.search(t).group(0))
    if me and re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(me), t):
        probs.append("username %s" % me)
    if probs:
        print("[FAIL] %s -> %s" % (f, "; ".join(probs))); fails += 1
    else:
        print("[PASS] %s" % f)

print("\n=== %d files scanned, %d with issues ===" % (len(files), fails))
print("OK to publish." if fails == 0 else "FIX the above before publishing.")
sys.exit(1 if fails else 0)
PY
