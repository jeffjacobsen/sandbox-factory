#!/usr/bin/env bash
# STAMPED by `/sssf install` from .claude/skills/sssf/templates/sandbox/gate_factory.sh.
# Edit the TEMPLATE and re-stamp; an edit here is a fork that the next install
# silently reverts. (Same rule as adws/adw_modules/ — customise by data, never by
# editing a stamped surface.)
#
# gate_factory.sh — THIS REPO's health assertions, declared in sandbox.yaml as a
# `health:` script entry and run INSIDE the sandbox by SETUP:
#
#   bash sandbox_mount/guest/gate_factory.sh <config-path>
#
# Assertion A (clean tree, HEAD matches the recorded sha) is NOT here. That one
# is universal — it is what caught 5,641 zero-byte files from an unsynced golden
# clone — so it stays builtin in the orchestrator and always runs. Everything
# below is the claim "the payload is an SSSF factory driven by pi over
# OpenRouter", which is a statement about THIS PROJECT, not about sandboxes.
# That is why it travels with the repo now instead of living in setup.just.
#
# Runs INSIDE the box on purpose: all three assertions need the runtime key,
# which is already in app/.env. The key never crosses the wire, and the gate
# proves the sandbox's own egress rather than the host's.
#
# $1 is the roster config path. It must be an ARGUMENT: this used to read
# $SSSF_CONFIG from the remote environment, but `ssh host 'cmd'` carries no
# environment at all, so the read always fell through to the default. On a
# fan-out where each arm ran a different roster, every arm was gated against
# models it would never call — the gate passed and told you nothing.
#
# Exit codes are the verdict: 2 = a roster model did not answer, 3 = pi reported
# no cost or the rate table is missing, 1 = anything else.
set -uo pipefail
cd "$HOME/app" || { echo "   no ~/app on this VM"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "   jq missing (it ships in the exeuntu image)"; exit 1; }

# Runtime key, read exactly the way provision.sh reads it. NEVER echoed.
KEY="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' .env \
       | tail -n 1 | sed -E 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//' || true)"
[ -n "$KEY" ] || { echo "   no OPENROUTER_API_KEY in app/.env — FILL did not inject the runtime key"; exit 1; }

key_usage() {   # dollars spent on this key so far
  curl -sS --max-time 60 https://openrouter.ai/api/v1/key \
    -H "Authorization: Bearer ${KEY}" | jq -r '.data.usage // 0'
}

usage_before="$(key_usage)"

# ── C: ping every model in the ACTIVE roster ─────────────────────────────
# Config values look like `openrouter/google/gemini-3.6-flash`: the first
# segment is pi's PROVIDER name, not part of the OpenRouter id, so strip it.
# $1 is the CONFIG argument, forwarded over ssh as a positional because the
# remote shell inherits no environment. Empty means "caller did not pick",
# so fall through to the old behaviour.
CFG="${1:-}"
[ -n "$CFG" ] || CFG="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"
[ -f "$CFG" ] || { echo "   missing ${CFG}"; exit 1; }
MODELS="$(awk '/^[[:space:]]*model:[[:space:]]/ {print $2}' "$CFG" \
          | sed 's|^openrouter/||' | sort -u)"
[ -n "$MODELS" ] || { echo "   parsed zero models out of ${CFG}"; exit 1; }

ping_fail=0
for m in $MODELS; do
  body="$(printf '{"model":"%s","max_tokens":256,"provider":{"zdr":true,"data_collection":"deny"},"messages":[{"role":"user","content":"ping - respond with pong"}]}' "$m")"
  resp="$(curl -sS --max-time 180 https://openrouter.ai/api/v1/chat/completions \
            -H "Authorization: Bearer ${KEY}" \
            -H 'Content-Type: application/json' \
            -d "$body" || true)"
  # Reasoning models answer with content=null and the text under .reasoning.
  # Accepting only .content here produces false failures on those models.
  text="$(printf '%s' "$resp" | jq -r '
    ((.choices[0].message.content // "") + (.choices[0].message.reasoning // ""))
  ' 2>/dev/null || true)"
  if [ -n "$text" ] && [ "$text" != "null" ]; then
    echo "   pass  ${m}"
  else
    err="$(printf '%s' "$resp" | jq -r '.error.message // .error // "no content and no error field"' 2>/dev/null || echo 'unparseable response')"
    echo "   FAIL  ${m}: ${err}"
    ping_fail=1
  fi
done

usage_after="$(key_usage)"

# ── D: pi actually REPORTS cost ──────────────────────────────────────────
# The thing being guarded is precise: adw_modules/agent_pi.py reads
# usage.cost.total straight out of pi, and pi defaults every rate to ZERO
# when models.json carries no `cost` block. A factory in that state runs
# fine and reports $0.0000 forever while genuinely spending. Observed: a
# 463.6k-token run logged $0.0000.
#
# So ask pi directly rather than asking OpenRouter. An earlier version
# diffed /api/v1/key usage before and after the pings; that is the WRONG
# INSTRUMENT and it false-failed this gate on the first live mount — four
# 250-token pings round to $0 in that endpoint, so a correctly configured
# sandbox looked broken. A real pi call on the cheapest roster model reports
# cost 4.3e-05 for one sentence, which is small but unambiguously > 0.
cost_fail=0
# jq, not python: an unindented line inside a recipe body TERMINATES the
# recipe, and multi-line python cannot survive that. jq ships in the image.
pi_cost="$(timeout 180 pi -p --mode json \
             --provider openrouter --model deepseek/deepseek-v4-flash-0731 \
             'Write one sentence about sandboxes.' 2>/dev/null \
           | jq -s '[.. | objects | select(has("cost")) | .cost.total // 0] | max // 0' \
           || echo 0)"
if awk -v c="$pi_cost" 'BEGIN { exit !(c > 0) }'; then
  echo "   pi reports cost \$${pi_cost} on a live call (rate table is loaded)"
else
  echo "   FAIL  pi reported cost 0 — models.json has no rate table, so every"
  echo "         run will log \$0.0000 while really spending money"
  cost_fail=1
fi
# Second half: the registry itself. Catches a partial rate table that the
# single call above happened not to touch. NOTE pi's schema requires ALL
# FOUR of input/output/cacheRead/cacheWrite — a partial block fails
# validation and pi then drops THE ENTIRE ROSTER, not just that model.
MJ="$HOME/.pi/agent/models.json"
if [ -f "$MJ" ] && jq -e '[.providers[].models[] | (.cost.input // 0)] | (length > 0) and all(. > 0)' "$MJ" >/dev/null 2>&1; then
  echo "   rate table present: every model in models.json has a non-zero input cost"
else
  echo "   FAIL  models.json is missing rates — pi will report \$0.0000 on every run"
  cost_fail=1
fi

# ── E: remaining credit on the runtime key ───────────────────────────────
# Remaining is COMPUTED from limit-usage rather than read from a
# limit_remaining field, so this cannot break on a field name we have not
# verified. A null limit means the key is uncapped.
kj="$(curl -sS --max-time 60 https://openrouter.ai/api/v1/key -H "Authorization: Bearer ${KEY}")"
printf '%s' "$kj" | jq -r '
  .data as $d
  | "   limit     " + (if $d.limit == null then "uncapped" else ("$" + ($d.limit|tostring)) end),
    "   used      $" + (($d.usage // 0)|tostring),
    "   remaining " + (if $d.limit == null then "uncapped" else ("$" + (($d.limit - ($d.usage // 0))|tostring)) end)
' || { echo "   could not read /api/v1/key"; exit 1; }

[ "$ping_fail" -eq 0 ] || exit 2
[ "$cost_fail" -eq 0 ] || exit 3
