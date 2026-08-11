# just/sandbox/manage/mod.just — auxiliary: preflight, readback, fleet ops.
#
# Nothing here is a phase. None of it writes to the run record, and apart from
# `reap` (which revokes keys, deliberately) none of it changes anything: these
# are the commands you run to find out where you stand, before or after the
# lifecycle does its work.
#
# A module inherits nothing, so the settings are repeated here with one more `..`
# than the parent. dotenv-load matters in this one: `reap` cannot list or delete
# without OPENROUTER_PROVISIONING_KEY, and `doctor` checks for it.
set working-directory := '../../..'
set positional-arguments
set dotenv-load

import 'list.just'
import 'harvest.just'
import 'reap.just'

# list the management commands
default:
    @just --list sbx::manage

# are the host prerequisites in place? run this before anything else
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    ok=0
    chk() { if eval "$2" >/dev/null 2>&1; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; ok=1; fi; }
    # Ask OpenRouter whether the key can actually manage keys. A management key and
    # an inference key are indistinguishable by prefix — both are sk-or-v1-… — so
    # "is it set" cannot catch the common mistake of pasting the inference key.
    # Without this, the wrong key first fails in CREATE, i.e. after a billable VM
    # already exists. 401 = wrong key type; 000 = no network.
    KEYCODE=""
    if [ -n "${OPENROUTER_PROVISIONING_KEY:-}" ]; then
        KEYCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
            -H "Authorization: Bearer ${OPENROUTER_PROVISIONING_KEY}" \
            https://openrouter.ai/api/v1/keys 2>/dev/null)
    fi
    # CREATE seeds the wildcard *.exe.xyz entry from the exe.dev one, so the real
    # precondition is that at least one of the two is present and trusted.
    KH=0
    ssh-keygen -F vm-probe.exe.xyz >/dev/null 2>&1 || ssh-keygen -F exe.dev >/dev/null 2>&1 || KH=1
    chk "ssh exe.dev reachable"            'ssh -o BatchMode=yes -o ConnectTimeout=15 exe.dev whoami'
    chk "known_hosts can verify a vm"      '[ "$KH" -eq 0 ]'
    chk "OPENROUTER_PROVISIONING_KEY set"  '[ -n "${OPENROUTER_PROVISIONING_KEY:-}" ]'
    chk "  ...and mints (management key)"  '[ "$KEYCODE" = "200" ]'
    chk "run_record helper runs"           'sandbox_mount/host/run_record.py list'
    # Writable, not merely resolvable: the store is created on the first mount,
    # and a create that cannot write the record mints a key with nowhere to
    # record it — the one failure that leaves money spending untracked.
    chk "run store writable"               'mkdir -p "$(sandbox_mount/host/run_record.py dir)" && [ -w "$(sandbox_mount/host/run_record.py dir)" ]'
    # The manifest is what makes the phases repo-agnostic, so a broken one is a
    # mount that fails in FILL or OBSERVE — after a billable VM exists. Every
    # rule it enforces (DNS-safe name, ports in the proxy's range, exactly one
    # public service) is a failure that otherwise shows up on live hardware.
    chk "sandbox.yaml valid"               'sandbox_mount/host/manifest.py check'
    # The base is OURS and is pushed every mount, so its absence breaks every
    # repo, not just this one. The hook is the target repo's and is optional —
    # `manifest.py check` already rejects a declared script that is not there.
    chk "base provisioner present"         '[ -r sandbox_mount/host/base_provision.sh ]'
    chk "models template has rates"        'python3 -c "import json;m=json.load(open(\"sandbox_mount/guest/models.json.tmpl\"))[\"providers\"][\"openrouter\"][\"models\"];assert all(set(x[\"cost\"])=={\"input\",\"output\",\"cacheRead\",\"cacheWrite\"} for x in m)"'
    chk "adw layer resolves"               'just --list adw'
    case "$KEYCODE" in
      401|403) echo "        hint: that key cannot manage keys. Create a MANAGEMENT key at"
               echo "              https://openrouter.ai/settings/management-keys — note that"
               echo "              /settings/keys makes inference keys, which look identical." ;;
      000)     echo "        hint: could not reach openrouter.ai — key left unverified." ;;
    esac
    [ "$KH" -eq 0 ] || echo "        hint: no exe.dev host key trusted yet. Run 'ssh exe.dev' once;
              CREATE copies that key to a *.exe.xyz entry so VMs verify."
    [ "$ok" -eq 0 ] && echo "  sbx doctor: OK" || { echo "  sbx doctor: FAILED"; exit 1; }
