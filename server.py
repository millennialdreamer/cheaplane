#!/usr/bin/env python3
"""
Cheaplane — delegate MCP server
===============================
Gives a main agent (e.g. Claude Code on a premium subscription) one extra tool to
offload *replaceable grunt work* to cheaper models, while it keeps the judgment
work (planning, architecture, final review) for itself — saving premium quota
without losing main-thread quality.

⭐ Billing isolation (the core idea): this process makes a plain HTTP call to a
   local OpenAI-compatible proxy with its own key. It never shares a process or
   credentials with the main agent's subscription auth — the two are physically
   isolated and can't cross.

⭐ Auto-routing (v0.2): with model="auto" (the default) Cheaplane picks the right
   cheap model from the task itself — code → deepseek, very long input → kimi,
   Chinese → qwen, multi-step → mimo, quick chores → flash. An explicit alias
   always wins.

⭐ Savings ledger (v0.2): each delegated call appends one line of METADATA ONLY
   (never the task content) to ~/.cheaplane/usage.jsonl, so the `savings` tool
   can show what you've kept off your premium quota. Opt out: DELEGATE_NO_LOG=1.

Dependencies: just the mcp SDK (FastMCP); everything else is the Python stdlib.
"""
import os
import json
import time
import urllib.request
import urllib.error

from mcp.server.fastmcp import FastMCP

# Upstream = local LiteLLM proxy by default; override via env to target any OpenAI-compatible endpoint
BASE_URL = os.environ.get("DELEGATE_BASE_URL", "http://localhost:4000")
API_KEY = os.environ.get("DELEGATE_API_KEY", "sk-litellm")  # a local proxy ignores the key; set a real one for real endpoints
TIMEOUT = int(os.environ.get("DELEGATE_TIMEOUT", "120"))    # per-call timeout (seconds); raise for long docs

# Savings ledger (metadata only — never task content). Opt out with DELEGATE_NO_LOG=1.
NO_LOG = os.environ.get("DELEGATE_NO_LOG") == "1"
LOG_PATH = os.path.expanduser(os.environ.get("DELEGATE_LOG", "~/.cheaplane/usage.jsonl"))

# Public list prices per 1M tokens (mid-2026) — used ONLY for the savings estimate.
PREMIUM_IN, PREMIUM_OUT = 5.00, 25.00   # Claude Opus API, for reference
CHEAP_IN, CHEAP_OUT = 0.14, 0.28        # DeepSeek-class

# Friendly aliases -> the model_name your proxy exposes for each cheap model.
# Defaults are the alias names themselves; remap without touching code via the
# DELEGATE_MODEL_MAP env var (JSON), e.g. '{"deepseek": "deepseek-v4-flash"}',
# or the hot-reload file below. A raw proxy model_name also works directly.
MODEL_ALIASES = {
    "deepseek": "deepseek",   # code / balanced
    "mimo":     "mimo",       # reasoning / multi-step
    "flash":    "flash",      # fast / formatting / translation
    "kimi":     "kimi",       # long documents, very large context
    "qwen":     "qwen",       # Chinese copywriting
}

_env_map = os.environ.get("DELEGATE_MODEL_MAP")
if _env_map:
    try:
        MODEL_ALIASES.update(json.loads(_env_map))
    except (ValueError, TypeError):
        pass  # malformed JSON -> keep the defaults above

# Hot-reload config file: re-read on every call so edits apply to all running
# sessions without a restart. Takes priority over env var + defaults.
_MAP_FILE = os.path.expanduser("~/.claude/delegate-model-map.json")

def _get_aliases() -> dict:
    """Return the alias map, preferring the hot-reload file over startup-time defaults."""
    try:
        with open(_MAP_FILE) as f:
            return {**MODEL_ALIASES, **json.load(f)}
    except (OSError, ValueError):
        return MODEL_ALIASES


def _pick_model(task: str) -> str:
    """Heuristic router for model='auto' — cheap, deterministic, explainable.

    Order matters: code beats length (code models handle long code), length beats
    language (long Chinese docs still want the long-context model), and the final
    fallback is the balanced code model.
    """
    t = task.lower()
    if any(s in t for s in ("```", "def ", "class ", "function", "refactor", "regex",
                            "stack trace", "compile", "typescript", "interface", "sql",
                            "json", "yaml", "unit test", "bug", "lint", "docstring")):
        return "deepseek"
    if len(task) > 12000:
        return "kimi"
    han = sum(1 for c in task if "一" <= c <= "鿿")
    if han > max(20, len(task) * 0.15):
        return "qwen"
    if any(s in t for s in ("step by step", "multi-step", "pipeline", "workflow",
                            "orchestrate", "subtasks", "break this down")):
        return "mimo"
    if len(task) < 600 and any(s in t for s in ("translate", "format", "reword", "rewrite",
                                                "fix typo", "rename", "bullet", "summarize")):
        return "flash"
    return "deepseek"


def _log(alias: str, real_model: str, usage: dict, task_chars: int, out_chars: int) -> None:
    """Append one metadata-only line to the savings ledger. Never logs content."""
    if NO_LOG:
        return
    try:
        parent = os.path.dirname(LOG_PATH)
        if parent:
            os.makedirs(parent, exist_ok=True)
        rec = {"ts": int(time.time()), "alias": alias, "model": real_model,
               "in_tok": usage.get("prompt_tokens"), "out_tok": usage.get("completion_tokens"),
               "task_chars": task_chars, "out_chars": out_chars}
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass  # bookkeeping must never break a delegation


mcp = FastMCP("delegate")


@mcp.tool()
def delegate(task: str, model: str = "auto", max_tokens: int = 4000) -> str:
    """Offload a self-contained subtask to a cheaper model and return its output.

    WHEN TO USE: hand off *replaceable grunt work* to save your premium tokens —
    boilerplate code, small bug fixes, formatting, translation, reading/summarizing
    long documents, drafting routine copy. Do NOT delegate judgment work (planning,
    architecture, final review, talking to the user) — keep that for yourself.

    The delegated model sees ONLY the `task` string and has NO access to this
    conversation. So make `task` fully self-contained (include all needed context).

    Args:
        task: Complete, self-contained instruction for the cheap model.
        model: "auto" (default) routes by task — code→deepseek, long docs→kimi,
               Chinese→qwen, multi-step→mimo, quick chores→flash. Or force an
               alias (deepseek/mimo/flash/kimi/qwen) or a raw proxy model_name.
        max_tokens: Output cap. Default 4000 (kept large so reasoning models that
               spend budget on hidden thinking still return non-empty text).

    Note: a call typically takes ~10-60s (longer for big inputs) and blocks until
    the cheap model returns, so prefer one focused task per call.

    Returns:
        The model's text output, or a string starting with "[delegate-error]" on failure.
    """
    if not task.strip():
        return "[delegate-error] empty task — pass the full, self-contained instruction."
    aliases = _get_aliases()
    alias = _pick_model(task) if model.lower() == "auto" else model
    real_model = aliases.get(alias.lower(), alias)
    body = json.dumps({
        "model": real_model,
        "messages": [{"role": "user", "content": task}],
        "max_tokens": max_tokens,
    }).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode("utf-8", "replace")
        return f"[delegate-error] HTTP {e.code} from {real_model}: {detail}"
    except Exception as e:
        return f"[delegate-error] {type(e).__name__}: {e} (is your proxy up at {BASE_URL}?)"

    ch = (d.get("choices") or [{}])[0]
    text = (ch.get("message") or {}).get("content") or ""
    if not text.strip():
        # A reasoning model may spend its budget on hidden thinking: content comes
        # back empty though the model is alive — hint to raise the cap.
        return (f"[delegate-error] empty output from {real_model} "
                f"(finish={ch.get('finish_reason')}); try a larger max_tokens.")
    _log(alias, real_model, d.get("usage") or {}, len(task), len(text))
    return text


@mcp.tool()
def savings() -> str:
    """Show what delegating has kept off your premium quota (estimates, list prices)."""
    try:
        with open(LOG_PATH, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return ("No delegations logged yet — run a few delegate() calls first. "
                "(Logging disabled? unset DELEGATE_NO_LOG.)")
    now = time.time()
    tot = {"n": 0, "in": 0, "out": 0}
    week = {"n": 0, "in": 0, "out": 0}
    for ln in lines:
        try:
            r = json.loads(ln)
        except ValueError:
            continue  # skip a corrupt line rather than fail the report
        it, ot = r.get("in_tok"), r.get("out_tok")
        i = it if isinstance(it, int) else max(1, r.get("task_chars", 0) // 4)   # ~4 chars/token fallback
        o = ot if isinstance(ot, int) else max(1, r.get("out_chars", 0) // 4)
        tot["n"] += 1; tot["in"] += i; tot["out"] += o
        if now - r.get("ts", 0) <= 7 * 86400:
            week["n"] += 1; week["in"] += i; week["out"] += o
    if not tot["n"]:
        return "No delegations logged yet — run a few delegate() calls first."

    def cost(b, in_rate, out_rate):
        return (b["in"] * in_rate + b["out"] * out_rate) / 1e6

    prem = cost(tot, PREMIUM_IN, PREMIUM_OUT)
    cheap = cost(tot, CHEAP_IN, CHEAP_OUT)
    week_prem = cost(week, PREMIUM_IN, PREMIUM_OUT)
    mult = (prem / cheap) if cheap else 0.0
    return (f"Cheaplane savings — all time\n"
            f"  delegated calls : {tot['n']}\n"
            f"  tokens offloaded: ~{tot['in']:,} in / ~{tot['out']:,} out\n"
            f"  premium cost avoided (Opus list): ~${prem:,.2f}\n"
            f"  actually spent (DeepSeek-class) : ~${cheap:,.2f}  (≈{mult:.0f}× cheaper)\n"
            f"  last 7 days     : {week['n']} calls, ~${week_prem:,.2f} avoided\n"
            f"(estimates from logged token counts at public list prices; your main thread\n"
            f" runs on subscription quota — the real win is the quota you kept)")


@mcp.tool()
def list_models() -> str:
    """List the model aliases available to delegate(), with their best use."""
    notes = {
        "auto":     "DEFAULT — routes by task (code→deepseek, long→kimi, zh→qwen, multi-step→mimo, chores→flash)",
        "deepseek": "code / balanced",
        "mimo":     "reasoning / multi-step agent chains",
        "flash":    "fast / formatting / translation",
        "kimi":     "long documents, very large context",
        "qwen":     "Chinese copywriting",
    }
    return json.dumps(notes, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    mcp.run()
