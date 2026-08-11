set dotenv-load
set positional-arguments

# Recipes run through an INTERACTIVE zsh so the engineer's own profile is live.
# just's default is a bare non-interactive `sh`, which never sources ~/.zshrc —
# so any harness installed as a shell function rather than a binary on PATH
# (`ipi`) failed with "command not found", while real binaries (`pi`, `claude`)
# happened to work. Same principle as adw_modules/utils.operator_env: what runs
# here should see exactly what the engineer sees.
#
# Two things to know: `.env` still wins over the profile (dotenv-load is applied
# to the recipe's environment), and a recipe with its own `#!` shebang bypasses
# this setting entirely — `kill` below runs as a bash script and only calls real
# binaries, which is why that is fine.
set shell := ["zsh", "-ic"]

# Silences macOS's "Saving session..." on every interactive shell exit.
export SHELL_SESSIONS_DISABLE := "1"

# default config every run uses — override: SSSF_CONFIG=other.yaml just adw sdlc "..."  (or pass --config in args)
# Still needed at root: the observability recipes below read the same roster/db.
config := env_var_or_default("SSSF_CONFIG", "adws/adw_sssf_config/sssf.config.yaml")

# Two layers, deliberately separate:
#   `mod adw`            — IN-sandbox execution. The ADWs themselves; identical
#                          whether run here or on a VM that has this repo.
#   `sbx` (external)     — OUT-of-sandbox orchestration. Creates, fills, and
#                          observes the VMs the ADWs run inside. It is a separate
#                          tool installed once per machine, so it no longer ships
#                          to the sandbox at all — and a sandbox could not use it
#                          anyway, because the exe.dev account and the OpenRouter
#                          provisioning key never leave the host.
# A module namespaces its recipes and inherits nothing from this file — see the
# header of just/adws.just for what that costs. An `import`, by contrast, shares
# its parent module's scope and working directory, which is why the phase files
# under just/sandbox/ are imports and carry no `set` lines of their own.

# boot and test the Inkwell app itself
mod inkwell 'just/inkwell.just'

# boot an orchestrator agent that works on THIS machine
mod local 'just/local.just'

# the ADWs themselves: just adw sdlc "..."
mod adw 'just/adws.just'

# Sandbox orchestration lives in its own tool now: https://github.com/jeffjacobsen/sbx
# It is installed once per machine rather than copied into each repo, because
# `reap` and `manage list` reason about a whole exe.dev + OpenRouter account —
# a copy per repo gives you one partial view per repo and a key can hide in the
# gap. What this repo keeps is sandbox.yaml, which describes only itself.
#
#   sbx mount my-task        (from this directory)
#   sbx manage list

# read the trace db: sessions, phases, tail, procs
mod obs 'just/obs.just'

# list commands
default:
    @just --list

# ── raw ADW runs live in the module: just adw ──────────────────────────────
