---
name: cheaplane-delegate
description: Use the `delegate` MCP tool to offload replaceable grunt work (boilerplate code, mechanical refactors, formatting, translation, summarizing long documents) to cheap models, so you keep your premium tokens for judgment work. Trigger whenever a subtask is mechanical, well-specified, and doesn't need your full reasoning.
---

# Delegating grunt work with `delegate`

You have an MCP tool `delegate(task)` backed by cheap models behind a local proxy. Use it to spend premium tokens only where your judgment matters.

## Delegate it (let the cheap model do it)
- Boilerplate / scaffolding code from a clear spec
- Mechanical refactors, formatting, lint fixes
- Translation; summarizing or extracting facts from long documents
- Routine prose: changelogs, docstrings, commit messages
- Anything you'd describe as "just churn this out"

## Do NOT delegate (you do it yourself)
- Planning, architecture, technical trade-offs
- **Final review of delegated output — always you**
- Talking to the user; judgment calls
- Anything where being subtly wrong is expensive

## Write a good `task`
The cheap model sees ONLY your `task` string — it has **no access to this conversation**. Make it self-contained: include the spec, the actual input, and the exact output format you want.
- ❌ "fix the bug"
- ✅ "Here is a Python function: <code>. It raises KeyError on an empty dict. Return a corrected version that returns 0 instead, code only."

## Picking a model
You usually don't: the default `model="auto"` routes by task — code → `deepseek`, long docs → `kimi`, Chinese copy → `qwen`, multi-step → `mimo`, quick chores → `flash`. Override with an explicit alias only when you know better (e.g. force `kimi` for a huge document).

## Review what comes back
Delegated output is a **draft from a cheaper model** — skim it before you rely on it. If it starts with `[delegate-error]`, the call failed: read the message, then retry, switch model, or just do it yourself. You own the final result.

Occasionally call `savings` to see how much premium quota delegation has kept off the main thread.
