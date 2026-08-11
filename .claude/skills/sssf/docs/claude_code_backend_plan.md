# Plan: Claude Code coding-agent backend (`agent_cc.py`)

**Status: deferred.** SSSF v1 is pi-only. Before implementing this, Anthropic
models will be exercised through the Pi coding agent (pi runs Anthropic models
natively — this backend is only needed for Claude Code's *harness*: its system
prompt, built-in subagents, skills, and permission machinery).

All file references are to `.claude/skills/sssf/templates/adws/adw_modules/`
unless noted. CLI facts below were verified against Claude Code v2.1.219 docs
(2026-08); re-verify flags before implementing.

## Why this is well-bounded

`agents.py` talks to the coding agent through a four-point surface, all in
`agent_pi`:

| Contract point | Call site | Claude Code equivalent |
|---|---|---|
| `run(request, on_event, on_spawn, on_exit) -> PiResult` | `agents.py` `send()` | `claude -p ... --output-format stream-json` subprocess, same tail-the-stream loop |
| `ToolCallTracker` | `agents.py` `_event_forwarder()` | fold `tool_use` / `tool_result` blocks keyed by `tool_use_id` |
| `resolve_model(pattern)` | `agents.py` `validate()` | alias/id sanity check — no catalog like pi's `models.json` |
| `context_window(...)` | inside `run()` | static lookup table (200k; 1M for `[1m]` models) |

`PiRequest` / `PiResult` in `data_types.py` are already backend-neutral —
**no schema changes required** (optional cosmetic rename to
`AgentRequest`/`AgentResult`).

Key semantic match: `claude -p --session-id <uuid>` **creates-or-resumes**,
exactly like pi's `--session-id`. The `send()` closure — where JSON-fix
retries and gate corrections re-enter the same session — works unchanged.
No create-vs-resume branching.

## Part 1 — implement `agent_cc.py` (~200–250 lines, mirror of `agent_pi.py`)

### 1.1 Command construction

```
claude -p <prompt>
  --output-format stream-json --verbose
  --session-id <uuid>                  # creates or continues
  --system-prompt <rendered system.md> # full replace, not --append-system-prompt
  --model <model>                      # alias (fable/opus/sonnet/haiku) or claude-* id
  --effort <level>                     # mapped from `thinking`, see 1.4
  --allowed-tools <translated list>    # see 1.5
  --permission-mode dontAsk            # see 1.6
  --setting-sources user               # or --bare; see 1.7
```

Run with `cwd=request.cwd`, `stdin=DEVNULL` (same hang rationale as
`agent_pi.run` — keep that comment), stream stdout line-by-line into
`request.raw_output_path`, bracket with `on_spawn(pid)` / `on_exit(pid)`.

### 1.2 Session ID translation

SSSF ids (`sssf-<adw_id>-<agent>-<rand>`) are not UUIDs; Claude Code requires
a UUID. Map deterministically:

```python
uuid.uuid5(SSSF_NAMESPACE, request.session_id)
```

Stable mapping means rejoining a session keeps working without touching
`_agent_session_id`. `request.session_dir` is ignored: there is no per-run
session-directory flag (sessions land in `~/.claude/projects/<hash>/`; only
`CLAUDE_CONFIG_DIR` relocates them, which would also relocate auth/settings).
`raw_output_path` remains the observability record, as it does for pi.

### 1.3 Stream parsing → `PiResult`

Events on stdout (newline-delimited JSON):

- `{"type":"system","subtype":"init",...}` — model, tools, session_id
- `{"type":"assistant","message":{content:[...], usage:{...}}}` — per-turn;
  `usage` has `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`
- `{"type":"user","message":{...}}` — carries `tool_result` blocks
- `{"type":"result", "result": <text>, "total_cost_usd", "usage": <cumulative>,
  "session_id", "modelUsage": {...}}` — final event

Mapping:

- `result.text` ← final `result` event text (fallback: last assistant text)
- `result.usage` ← `UsageBreakdown` with `cache_read_input_tokens →
  cache_read_tokens`, `cache_creation_input_tokens → cache_write_tokens`
- `result.tokens` ← sum of per-turn context totals (pi parity)
- `result.context_tokens` ← last valid assistant turn's
  input + cache_read + cache_creation + output (mirror `_context_tokens`)
- `result.cost` ← `total_cost_usd`. **Degradation:** Claude Code reports only
  a total estimate — `UsageBreakdown` per-component costs stay 0, only
  `total_cost` is filled. (`modelUsage` has per-model `costUSD` if we ever
  want more.)
- `result.context_window` ← static table keyed off the model id; 0 if unknown.

### 1.4 Thinking → effort mapping

Pi scale `off|minimal|low|medium|high|xhigh|max` → Claude Code
`--effort low|medium|high|xhigh|max`: collapse `off/minimal/low → low`,
rest map 1:1.

### 1.5 Tool-name translation

Config keeps pi names everywhere (so `defaults.tools` stays shared);
`agent_cc.py` owns the table:

| pi | Claude Code |
|---|---|
| read | Read |
| bash | Bash |
| edit | Edit |
| write | Write |
| grep | Grep |
| find | Glob |
| ls | (no builtin — fold into Bash, or drop) |

Extension tool names (`subagent_*`) have no counterpart — see 2.2.

### 1.6 Permissions

Unattended `-p` runs abort when a tool needs approval nobody can grant. Pass
`--allowed-tools` (auto-approves listed tools) plus `--permission-mode
dontAsk` (auto-denies the rest). `bypassPermissions` is defensible too, since
SSSF's real guardrail is `permissions.py` post-hoc `writes:` enforcement
(filesystem-based, backend-agnostic, keeps working as-is) — but `dontAsk` +
allowlist is the safer default.

### 1.7 Settings isolation

Headless Claude Code loads the target repo's `.claude/` settings, hooks, and
CLAUDE.md by default. Pass `--setting-sources user` (or `--bare` for maximum
determinism — but `--bare` also disables skills/CLAUDE.md the operator might
want). Decide at implementation time; default to `--setting-sources user`.

### 1.8 `ToolCallTracker` port

Same fold as pi's: a `tool_use` content block in an assistant message opens
the call (starts wall + monotonic clocks); the matching `tool_result` block
(by `tool_use_id`) in a user message emits the one normalized record. Reuse
`_label`/`_clip`/`PRIMARY_ARGS` — Claude Code's arg names (`command`,
`file_path`, `pattern`, ...) already match. Consider hoisting those helpers
into a shared module instead of duplicating.

### 1.9 `resolve_model` / validation

No catalog to consult. Accept aliases (`fable`, `opus`, `sonnet`, `haiku`,
`default`) and `claude-*` ids; reject anything containing `/` (that's a pi
pattern — mispaired config should fail fast at `validate()`, not mid-run).

## Part 2 — dispatch changes in `agents.py` (~20 lines)

2.1 **Backend registry.**
`BACKENDS = {"pi": agent_pi, "claude_code": agent_cc}`. Use it in `send()`
(`backend.run(...)`) and pass the backend into `_event_forwarder` so it
constructs `backend.ToolCallTracker()` (it currently hardcodes pi's).

2.2 **`validate()`.** Remove the pi-only rejection. Route each agent's model
through its own backend's `resolve_model`. Add: reject `harness_engineering`
on `claude_code` agents (pi `-e *.ts` extensions don't port; nearest
substitutes — `--mcp-config` or Claude Code's built-in subagents — are future
scope).

2.3 **`_agent_session_id()`.** Currently re-keys the session when `model`
changes; also re-key when `coding_agent` changes. `agent_map` already stores
`coding_agent`, so it's one more condition in the mismatch check.

2.4 **Docs/comments.** Update "v1 is pi-only" in `sssf.config.yaml` (header +
defaults comment), the `agent_cc.py` docstring (which references the outdated
`--resume` approach — `--session-id` alone is correct), and SKILL.md if it
repeats the claim.

## Part 3 — per-agent backend mixing

Already designed in: `coding_agent` is a per-agent `AgentConfig` field,
`load_config` merges defaults into each agent, and the tracer records
`coding_agent` per agent session. Once Part 2 lands, this works with zero
further plumbing:

```yaml
agents:
  - name: planner
    coding_agent: claude_code
    model: fable
    thinking: high
  - name: builder
    coding_agent: pi
    model: fireworks/accounts/fireworks/models/kimi-k3
```

Agents never share sessions — they hand off through typed envelopes and
`context_handoff/` — so pi and Claude Code agents interoperate unaware of
each other. Gates, `permissions.py`, tracer, and visualizer are all
backend-agnostic.

Caveats to carry into implementation:

1. **Model strings are backend-scoped.** `openai/gpt-5.6-terra` means nothing
   to Claude Code; `sonnet` means nothing to pi. Per-backend validation
   (2.2) is what catches mispairings early.
2. **Tool lists stay pi-named** in config; translation lives in `agent_cc.py`
   (1.5).
3. **`harness_engineering` is pi-only.** The shipped planner and scout depend
   on `subagents.ts`; as `claude_code` agents they'd drop those entries, use
   Claude Code's built-in Agent/Task tool, and need small prompt edits
   (prompts reference `subagent_*` tools by name).
4. **Coarser telemetry for claude_code agents:** total-only cost, context
   window from a lookup table rather than a registry.

## Suggested implementation order

1. `agent_cc.py` end-to-end against a throwaway session (run + stream parse +
   result mapping), tested standalone before wiring in.
2. `ToolCallTracker` port + shared-helper hoist.
3. `agents.py` dispatch + validation (Part 2).
4. Config/doc updates, then a mixed-roster smoke run (one claude_code agent,
   rest pi) through an existing ADW.
