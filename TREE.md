# TREE

Every file that matters, and why it exists. Three layers stack here:

| Layer | What it is | Where it runs |
| --- | --- | --- |
| **app** | Inkwell, a small blog-writing app | wherever it is served |
| **factory** | the Super Simple Software Factory: deterministic Python owns the graph, coding agents are bounded phases inside it | wherever it is invoked |
| **sandbox** | six host-side phases that stand the other two up on a throwaway exe.dev VM | host only — it needs credentials a sandbox never has |

The command surface mirrors that split: `just adw` (the workflows), `just sbx` (the VMs),
`just local` (boot an orchestrator here), `just obs` (read the traces).

---

## Root

```
justfile              4 namespaces and nothing else: adw, sbx, local, obs.
sandbox.yaml          how THIS repo runs in a box: clone URL, provision script, secrets,
                      services + ports, kickoff command. The phases describe HOW to mount
                      a repo; this describes WHICH. Every field in it is read by a phase —
                      when one stops being read, delete it.
README.md             the three layers, the layout, and how to run each one.
TREE.md               this file.
.env.sample           OPENROUTER_PROVISIONING_KEY is HOST-ONLY; the runtime key is minted
                      per sandbox. Never commit .env (gitignored).
LICENSE               MIT.
```

## `just/` — the command surface

```
just/adws.just        the `adw` namespace: 14 ADW recipes. Carries `set working-directory`,
                      its own `config`, AND `set positional-arguments` — a module inherits
                      NOTHING, and without that last line $@ is empty and every argument is
                      silently dropped.
just/local.just       the `local` namespace: cc / pi / ipi, an orchestrator agent on THIS
                      machine. Declares `shell := ["zsh","-ic"]` because `ipi` is a zsh
                      FUNCTION, not a binary.
just/obs.just         the `obs` namespace: sessions, phases, tail, procs, kill, rosters, ui.
                      Meant to work inside a sandbox too — reading your own traces is wanted there.
just/                 sandbox orchestration MOVED OUT: it is https://github.com/jeffjacobsen/sbx
                      now, installed once per machine rather than copied per repo, because
                      `reap` and `manage list` reason about a whole exe.dev account. What
                      this repo keeps is sandbox.yaml, which describes only itself.

```

## `sandbox_mount/` — what crosses the boundary

```
host/                 MOVED to https://github.com/jeffjacobsen/sbx — run_record.py,
                      manifest.py, runs_table.py and base_provision.sh belong to the
                      orchestrator, which is installed once per machine.

guest/provision.sh    THIS repo's optional project hook, run INSIDE the VM by the base.
                      Writes models.json, builds the UI, inits the trace db. Does NOT touch
                      the sentinel — the base does, after this returns.
guest/gate_factory.sh  THIS repo's health assertions (roster ping, non-zero cost, credit),
                      declared in sandbox.yaml. Stamped by /sssf install — edit the template.
guest/models.json.tmpl  10 models, each with a FOUR-field cost block. A partial block fails
                      schema validation and pi drops the entire roster; with no rates pi
                      reports $0.0000 forever while genuinely spending.
```

## `adws/` — the factory

```
examples/             worked manifests for repos that are not this one. Point the phases at
                      one with SBX_MANIFEST=<path>. mdn-beginner-html-site declares no
                      provision, no health and no kickoff — the zero-files-added case.

adws/adw_*.py         12 workflows. Each opens with a `Phases:` docstring that is its chain
                      in one line. Thin on purpose: logic lives in adw_modules/.
adws/adw_modules/     agents.py (roster + validation), agent_pi.py / agent_cc.py (harness
                      adapters), data_types.py (typed envelopes), gates.py, quality.py
                      (deterministic checks incl. the test suite), tracer.py (the trace db),
                      session.py, runner.py, permissions.py, git_helper.py.
adws/adw_sssf_config/ sssf.config.yaml (cheap roster) and sssf.frontier.config.yaml.
                      Every model is `openrouter/<id>`; the first slash splits provider
                      from model id.
adws/adw_data/        runtime: sessions/, prompt_engineering/, harness_engineering/, and
                      sssf.db. NEVER edit sessions/ — it is the run record.
```

## `apps/inkwell/` — the app

```
server.ts             Bun + bun:sqlite, zero dependencies. Port 4501.
server.test.ts        30 tests. `bun test apps/inkwell/server.test.ts` is what the factory's
                      test phase runs, by name, as code rather than an agent decision.
public/               vanilla JS front end: app.js, index.html, style.css.
```

## `.claude/skills/` — the three skills

```
sssf/                 the factory skill: SKILL.md, 9 cookbooks, 3 references, and
                      apps/visualizer/ (the observability UI: Bun server + Vue, polls
                      sssf.db, serves dist/ when built). Portable — it stamps other repos.
sssf-sandbox-orchestrator/  HOST-ONLY skill that drives the six phases. SKILL.md, 7
                      cookbooks (just_command_model is the load-bearing one), 4 references
                      (gotchas.md is every measured trap).
sandbox-exe-dev/      exe.dev VM control: SKILL.md + a vendored `exedev` CLI. Also host-only.
commands/prime.md     `/prime` — boots a net-new agent on this whole system.
```

## Docs and inputs

```
specs/sandbox-mount-system.html   THE PLAN, and the working checklist. Live checkboxes record
                      what was verified ON HARDWARE. An unchecked box means "not proven",
                      not "not written". Opens in a browser. Read the "Where this stands"
                      section first.
ai_docs/exedev_sandbox_mounting.md   every exe.dev fact, measured on live VMs. Several
                      obvious designs were killed by these measurements. Do not re-derive.
prompts/              five ready-made tasks to point the factory at (01-05), usable verbatim:
                      `sbx lifecycle execute <id> "$(cat prompts/01-fts5-search.md)"`.
specs/*.md            plans the factory itself wrote on earlier runs.
app_docs/             write-ups the factory produced after those runs.
images/               diagrams used by the README.
```

---

## The five things that will bite you

1. **A just module inherits nothing** — not variables, not settings, and its cwd is its own
   directory. Every module here re-declares what it needs, and each missing line fails in a
   different silent way.
2. **`import` is not optional in just** — a missing source file is a parse error that kills the
   whole justfile. This used to break stripped sandboxes; the strip is gone, so it cannot now.
3. **`pi --list-models` exits 0 while printing "No models available."** Never trust `$?`.
4. **No rate table means `$0.0000` forever** while really spending. A 463.6k-token run logged zero
   before this was found.
5. **Never `apt` in the sandbox path** — ~148 kB/s from the `dal` region, ~35s per package. bun and
   just come from their own CDNs in about a second.
