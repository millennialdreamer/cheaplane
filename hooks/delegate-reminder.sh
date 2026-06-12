#!/usr/bin/env bash
# Cheaplane — re-injects the "use delegate" reminder on every prompt.
#
# Why this exists: an agent forgets a tool once the conversation grows — the
# instruction sinks down the context and attention moves to the task at hand.
# Re-injecting a short reminder every turn is what turns an *installed* tool into
# a *used* one. Install with `bash install-hook.sh` (or wire it into settings.json
# by hand — see the README section "Make your agent actually use it").
#
# This hook fires on every prompt and always injects the same reminder, so it
# ignores the prompt payload; draining stdin just keeps strict shells happy.
cat >/dev/null 2>&1
python3 <<'PY'
import json
msg = (
    "You have a delegate(task, model) MCP tool (Cheaplane) that offloads work to "
    "cheaper models behind your local proxy. Before doing any REPLACEABLE GRUNT WORK "
    "yourself — boilerplate, formatting, translation, summarizing long docs, "
    "mechanical refactors, routine copy — delegate it to save your premium tokens/quota. "
    "Keep JUDGMENT WORK (architecture, technical trade-offs, final review, talking to "
    "the user) for yourself. Always review delegated output; make each task self-contained."
)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit", "additionalContext": msg
}}))
PY
