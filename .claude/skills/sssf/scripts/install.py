#!/usr/bin/env -S uv run
# /// script
# dependencies = []
# ///
"""/install — stamp the SSSF factory from the skill into the cwd. Idempotent.

Usage:
    uv run <skill>/scripts/install.py [--force]

Stamps: adws/ (modules + starter ADWs), adws/adw_data/prompt_engineering/
(4 starter agents), adws/adw_sssf_config/sssf.config.yaml, .env.sample,
.gitignore entries.
Existing files are skipped unless --force.
"""

import argparse
import shutil
import sys
from pathlib import Path

TEMPLATES = Path(__file__).resolve().parent.parent / "templates"

GITIGNORE_ENTRIES = [
    "adws/adw_data/sessions/",
    "adws/adw_data/sssf.db*",
    ".env",
    # The ADWs are Python, so importing adw_modules writes bytecode next to it.
    # Chains that end in a commit phase call `git add -A`, so without this a
    # stamped repo commits its own .pyc files — 15 of them showed up in the
    # first repo that was ever installed into from scratch.
    "__pycache__/",
    "*.pyc",
]


def stamp(src: Path, dest: Path, force: bool, stamped: list, skipped: list) -> None:
    if src.is_dir():
        for child in sorted(src.iterdir()):
            if child.name == "__pycache__":
                continue
            stamp(child, dest / child.name, force, stamped, skipped)
        return
    if dest.exists() and not force:
        skipped.append(str(dest))
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    stamped.append(str(dest))


def ensure_gitignore(root: Path, stamped: list) -> None:
    gitignore = root / ".gitignore"
    existing = gitignore.read_text().splitlines() if gitignore.exists() else []
    missing = [e for e in GITIGNORE_ENTRIES if e not in existing]
    if missing:
        with gitignore.open("a") as f:
            f.write("\n# sssf runtime\n" + "\n".join(missing) + "\n")
        stamped.append(f"{gitignore} (+{len(missing)} entries)")


def check_drift(root: Path) -> int:
    """Report stamped files that differ from the templates they came from.

    The ownership line is the point. adws/adw_modules/ is VENDORED: it belongs
    to this skill, and a repo that edits it has forked, silently, until an
    upgrade quietly reverts the edit or an ADW calls a name that was renamed.
    This makes that visible, so an upgrade is a decision instead of a merge
    nobody attempts.

    Reports, never repairs. What to do about a drifted file is a judgement call
    — it may be a customisation that should move into config, or a fix that
    should go upstream — and a tool that silently overwrote it would destroy the
    only copy of that work.
    """
    drifted, missing = [], []
    for src in sorted((TEMPLATES / "adws" / "adw_modules").rglob("*")):
        if src.is_dir() or "__pycache__" in src.parts:
            continue
        dest = root / "adws" / "adw_modules" / src.relative_to(TEMPLATES / "adws" / "adw_modules")
        if not dest.exists():
            missing.append(dest)
        elif dest.read_bytes() != src.read_bytes():
            drifted.append(dest)

    version = (TEMPLATES / "adws" / "adw_modules" / "VERSION")
    stamped = (root / "adws" / "adw_modules" / "VERSION")
    tv = version.read_text().splitlines()[0].strip() if version.exists() else "?"
    sv = stamped.read_text().splitlines()[0].strip() if stamped.exists() else "(absent)"
    print(f"adw_modules: template {tv}, stamped {sv}")

    if not drifted and not missing:
        print("no drift — every vendored file matches the template")
        return 0
    for d in missing:
        print(f"  MISSING  {d.relative_to(root)}")
    for d in drifted:
        print(f"  DRIFTED  {d.relative_to(root)}")
    print("\nA drifted file is a FORK, not a customisation. Move the change into")
    print("data if you can — commands belong in the `quality:` block of")
    print("sssf.config.yaml, models in `agents:`, prompts in adw_data/. If it is a")
    print("genuine fix, send it upstream. `--force` re-stamps and DISCARDS the edit.")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="overwrite existing files")
    parser.add_argument("--check", action="store_true",
                        help="report vendored files that drifted from the templates, then exit")
    parser.add_argument("--adws", default="",
                        help="comma-separated ADW names to stamp (default: all). "
                             "A small repo should not inherit nine workflows it will never run.")
    args = parser.parse_args()

    if args.check:
        return check_drift(Path.cwd())

    root = Path.cwd()
    stamped, skipped = [], []

    # The examples are a CATALOGUE you select from, not a payload you receive
    # whole. adw_modules/ and adw_data/ always come; the adw_*.py workflows are
    # filtered, because a repo that will only ever run `sdlc` should not carry
    # eleven other chains it has to read past.
    wanted = {n.strip() for n in args.adws.split(",") if n.strip()}
    if wanted:
        stamp(TEMPLATES / "adws" / "adw_modules", root / "adws" / "adw_modules",
              args.force, stamped, skipped)
        available = {p.stem[len("adw_"):]: p
                     for p in (TEMPLATES / "adws").glob("adw_*.py")}
        unknown = wanted - set(available)
        if unknown:
            print(f"unknown ADW(s): {', '.join(sorted(unknown))}", file=sys.stderr)
            print(f"available: {', '.join(sorted(available))}", file=sys.stderr)
            return 2
        for name in sorted(wanted):
            stamp(available[name], root / "adws" / available[name].name,
                  args.force, stamped, skipped)
    else:
        stamp(TEMPLATES / "adws", root / "adws", args.force, stamped, skipped)
    stamp(TEMPLATES / "prompt_engineering",
          root / "adws" / "adw_data" / "prompt_engineering", args.force, stamped, skipped)
    stamp(TEMPLATES / "harness_engineering",
          root / "adws" / "adw_data" / "harness_engineering", args.force, stamped, skipped)
    stamp(TEMPLATES / "sssf.config.yaml",
          root / "adws" / "adw_sssf_config" / "sssf.config.yaml",
          args.force, stamped, skipped)
    stamp(TEMPLATES / "env.sample", root / ".env.sample", args.force, stamped, skipped)
    # The recipes are part of the operating experience, and several cookbooks
    # plus the run banner tell you to use them, so a stamped repo has to have
    # them. Skipped like any other file if the repo already has a justfile.
    stamp(TEMPLATES / "justfile", root / "justfile", args.force, stamped, skipped)
    # The factory's own sandbox health assertions. A stamped repo is then
    # sandbox-ready by construction: the gates that prove "pi is healthy and the
    # roster answers" travel with the factory that makes those claims, rather
    # than living in the mount system, which has no business knowing what pi is.
    stamp(TEMPLATES / "sandbox" / "gate_factory.sh",
          root / "sandbox_mount" / "guest" / "gate_factory.sh", args.force, stamped, skipped)
    stamp(TEMPLATES / "sandbox" / "health.yaml",
          root / "sandbox_mount" / "sandbox_health.yaml", args.force, stamped, skipped)
    ensure_gitignore(root, stamped)

    print(f"sssf installed into {root}")
    print(f"  stamped: {len(stamped)} file(s)")
    for s in stamped:
        print(f"    + {s}")
    if skipped:
        print(f"  skipped (already exist, use --force to overwrite): {len(skipped)}")
    print("\nnext steps:")
    print("  1. cp .env.sample .env   # then set the key(s) your roster needs")
    print("  2. just demo             # two cheap read-only runs, end to end")
    print("  3. just sessions         # what just happened")
    print("  4. just obs              # the trace UI, needs bun")
    print("\n  to mount this repo in a sandbox, paste sandbox_mount/sandbox_health.yaml")
    print("  into the health: block of its sandbox.yaml")
    print("\n  no just? the raw form of step 2 is:")
    print("     uv run adws/adw_prompt.py \"say hello\" --agent scout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
