#!/usr/bin/env bash
# Which trace db should `obs` read? Prints one absolute path, or explains why not.
#
# A file rather than five copies inline: every obs recipe needs this answer, and
# a resolution rule that exists in five places is a rule that will disagree with
# itself. An unindented line inside a just recipe body also TERMINATES the
# recipe, so multi-line logic wants to live outside one anyway.
#
# WHY THIS EXISTS AT ALL. The visualizer was always built to be pointed — `--db`
# wins, then SSSF_DB, then the cwd default — because "the db lives in the TARGET
# repo". Teardown deliberately harvests each run's sssf.db home for the same
# reason. But the obs recipes hardcoded this repo's db, so the one machine that
# collects every run's trace could only ever look at its own. This closes that.
#
# Three forms, most specific first:
#
#   (nothing)                    this repo — adws/adw_data/sssf.db. The default,
#                                and what running obs inside a sandbox wants.
#   <run-id>                     a harvested run, from the sbx state store
#   <path>/<to>.db               any db you name
set -euo pipefail

SRC="${1:-}"
REPO_DB="$PWD/adws/adw_data/sssf.db"

# The sbx run store. Same resolution order sbx itself uses, so a fleet pointed
# somewhere else with SBX_STATE_DIR stays readable from here.
runs_dir() {
    if [ -n "${SBX_STATE_DIR:-}" ]; then printf '%s/runs' "$SBX_STATE_DIR"; return; fi
    printf '%s/sbx/runs' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Is this an initialised trace db, or just a file? A db created but never
# written by an ADW is 0 bytes, and sqlite answers "no such table: sessions" —
# true, and useless to whoever typed the command.
#
# SCHEMA, not rows. A db with the tables and zero sessions is perfectly valid to
# point a UI at: it is a repo that has not run anything YET, which is a different
# thing from a file that is not a trace db at all. Naming this `has_sessions`
# once cost a wrong test assertion, because it reads as a claim about rows.
is_trace_db() {
    [ -s "$1" ] || return 1
    [ -n "$(sqlite3 "$1" "select name from sqlite_master where type='table' and name='sessions';" 2>/dev/null)" ]
}

harvested() {   # every harvested run, with how many sessions it actually holds
    local d; d="$(runs_dir)"
    [ -d "$d" ] || return 0
    for a in "$d"/*-artifacts; do
        local db="$a/adws/adw_data/sssf.db"
        [ -f "$db" ] || continue
        local id n
        id="$(basename "$a" | sed 's/-artifacts$//')"
        if is_trace_db "$db"; then
            n="$(sqlite3 "$db" "select count(*) from sessions;" 2>/dev/null || echo 0)"
            printf '%s\t%s run(s)\n' "$id" "$n"
        else
            printf '%s\t%s\n' "$id" "no runs recorded"
        fi
    done
}

die_with_options() {
    echo "obs: $1" >&2
    local runs; runs="$(harvested)"
    if [ -n "$runs" ]; then
        echo "" >&2
        echo "harvested runs on this machine:" >&2
        printf '%s\n' "$runs" | awk -F'\t' '{printf "  %-46s %s\n", $1, $2}' >&2
    else
        echo "no harvested runs yet — sbx manage harvest <run-id> brings one home" >&2
    fi
    exit 1
}

if [ -z "$SRC" ]; then
    # This repo. Since the factory's own payload moved out, this db is usually
    # empty here — so say that, and point at what IS readable, rather than
    # letting sqlite report a missing table five stack frames later.
    is_trace_db "$REPO_DB" || die_with_options \
        "this repo has no trace db yet (${REPO_DB#$PWD/} is empty or absent)"
    printf '%s\n' "$REPO_DB"
    exit 0
fi

case "$SRC" in
    */*|*.db)
        # An explicit path. Absolute-ised so the visualizer, which runs from the
        # app directory, resolves it the same way every other caller does.
        case "$SRC" in /*) DB="$SRC" ;; *) DB="$PWD/$SRC" ;; esac
        [ -f "$DB" ] || die_with_options "no trace db at $DB"
        is_trace_db "$DB" || die_with_options "$DB is not a trace db (no sessions table)"
        printf '%s\n' "$DB"
        ;;
    *)
        DB="$(runs_dir)/${SRC}-artifacts/adws/adw_data/sssf.db"
        [ -f "$DB" ] || die_with_options "run '$SRC' has no harvested trace db at $DB"
        is_trace_db "$DB" || die_with_options "run '$SRC' harvested a file that is not a trace db"
        printf '%s\n' "$DB"
        ;;
esac
