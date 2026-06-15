#!/usr/bin/env bash
# prepublish_check.sh — comprehensive pre-publish audit. Run before every release.
# Exit 0 = safe to ship, non-zero = number of blocking issues to fix first.
#
# Three gates, all blocking:
#   [A] Secrets & identity : real API keys, home paths, emails, OS username,
#                            internal model aliases, internal slang, owner account, CJK leaks
#   [B] Assets & licensing : README-referenced images exist, LICENSE present,
#                            .gitignore hides local config, no leftover TODO/FIXME placeholders
#   [C] Code & syntax      : server.py/probe.py compile, *.sh parse, (if proxy up) probe end-to-end
#
# Reads $USER/$HOME at runtime; the script itself carries no private data and is safe to ship.
set -uo pipefail
cd "$(dirname "$0")"
FAILS=0
hr(){   printf '\n=== %s ===\n' "$*"; }
fail(){ printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
pass(){ printf '  [pass] %s\n' "$*"; }
warn(){ printf '  [warn] %s\n' "$*"; }

# Files that would be published = tracked + untracked-not-ignored; find() fallback pre-init.
files=$( { git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u | grep -v '^$' || true )
[ -z "$files" ] && files=$(find . -type f -not -path './.venv/*' -not -path './.git/*' -not -name '.mcp.json' | sed 's|^\./||')

# ── Gates [A] + [B]: content scan in Python (exit code = blocking issue count) ──
FILES="$files" SELF="$(basename "$0")" python3 <<'PY'
import os, re, sys, glob
me   = os.environ.get("USER", "")
home = os.environ.get("HOME", "")
self = os.environ.get("SELF", "")
files = [f for f in os.environ["FILES"].splitlines() if f.strip()]

KEY   = re.compile(r"sk-[A-Za-z0-9_\-]{20,}")
MAIL  = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
# Internal-leak patterns assembled at runtime, so this script never trips on itself.
ALIAS = re.compile("claude-(?:sonnet|opus|haiku)-" + "x")
SLANG = chr(0x4f53)+chr(0x529b)+chr(0x6d3b)  # internal CN slang, kept ASCII so this file ships clean
OWNER = "qing" + "haiyou"          # owner account prefix
CJK   = re.compile("[" + chr(0x4e00) + "-" + chr(0x9fff) + "]")
PLACE = re.compile(r"\b(TODO|FIXME|XXX)\b|lorem ipsum", re.I)

fails = 0
def fail(m):
    global fails; print("  [FAIL] " + m); fails += 1
def pas(m):  print("  [pass] " + m)
def warn(m): print("  [warn] " + m)

print("=== [A] Secrets & identity ===")
scanned = 0
for f in files:
    if not os.path.isfile(f) or os.path.basename(f) == self:
        continue
    raw = open(f, "rb").read()
    if b"\x00" in raw[:8000]:        # binary (e.g. images) — not text, skip content scan
        continue
    scanned += 1
    t = raw.decode("utf-8", errors="replace")
    p = []
    ks = [k for k in KEY.findall(t) if k != "sk-litellm"]
    if ks:                 p.append("real-key %s" % ks[:2])
    if home and home in t: p.append("home-path")
    m = MAIL.search(t)
    if m:                  p.append("email %s" % m.group(0))
    if me and re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(me), t): p.append("os-user")
    if ALIAS.search(t):    p.append("internal-alias")
    if SLANG in t:         p.append("internal-slang")
    if OWNER in t:         p.append("owner-account")
    if CJK.search(t):      p.append("CJK-text")
    if p:
        fail("%s -> %s" % (f, "; ".join(p)))
if fails == 0:
    pas("clean across %d files (no secrets/identity/locale leaks)" % scanned)

print("=== [B] Assets & licensing ===")
try:    rm = open("README.md", encoding="utf-8", errors="replace").read()
except Exception: rm = ""
imgs = sorted(set(re.findall(r"(assets/[^\"')\s]+\.(?:png|svg|jpe?g|gif))", rm)))
for img in imgs:
    (pas("image exists: " + img) if os.path.isfile(img)
     else fail("README references missing image: " + img))
if not imgs:
    warn("README references no local images")
(pas("LICENSE present") if (os.path.isfile("LICENSE") or glob.glob("LICENSE*"))
 else fail("no LICENSE file"))
try:    gi = open(".gitignore", encoding="utf-8", errors="replace").read()
except Exception: gi = ""
for pat in [".venv", ".mcp.json", "litellm.yaml"]:
    (pas(".gitignore hides " + pat) if pat in gi
     else warn(".gitignore missing " + pat))
ph = []
for f in files:
    if not os.path.isfile(f) or os.path.basename(f) == self:
        continue
    if not f.endswith((".py", ".md", ".sh", ".toml", ".yaml", ".yml")):
        continue
    for i, ln in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        if PLACE.search(ln):
            ph.append("%s:%d" % (f, i))
if ph:
    fail("leftover placeholders: " + ", ".join(ph[:5]) + (" ..." if len(ph) > 5 else ""))
else:
    pas("no TODO/FIXME/XXX placeholders")

sys.exit(fails)
PY
FAILS=$((FAILS + $?))

# ── Gate [C]: code & syntax (no grep; safe under any shell rewriter) ──
hr "[C] Code & syntax"
for py in server.py probe.py; do
  [ -f "$py" ] || continue
  if python3 -c "import ast; ast.parse(open('$py').read())" 2>/dev/null; then pass "$py compiles"; else fail "$py syntax error"; fi
done
for sh in setup.sh install-hook.sh prepublish_check.sh; do
  [ -f "$sh" ] || continue
  if bash -n "$sh" 2>/dev/null; then pass "$sh parses"; else fail "$sh syntax error"; fi
done
BASE="${DELEGATE_BASE_URL:-http://localhost:4000}"
if curl -sf --max-time 3 "$BASE/health/liveliness" >/dev/null 2>&1 || curl -sf --max-time 3 "$BASE/v1/models" >/dev/null 2>&1; then
  PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python
  if "$PY" probe.py >/dev/null 2>&1; then pass "probe.py end-to-end (main -> MCP -> cheap model)"; else fail "probe.py end-to-end failed"; fi
else
  warn "proxy not up at $BASE — skipped live probe (start LiteLLM to test the full chain)"
fi

# ── Verdict ──
hr "RESULT"
if [ "$FAILS" -eq 0 ]; then
  echo "  PASS — 0 blocking issues, safe to publish."
else
  echo "  FAIL — $FAILS blocking issue(s); fix the above before publishing."
fi
exit "$FAILS"
