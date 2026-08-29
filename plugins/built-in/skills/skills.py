#!/usr/bin/env python3
"""
Aulthium hook plugin: "skills"

Verified against aulthium.sh's actual source (web_search_query_plugin_hook
and handle_repl_input / plugin_toggle_prefix_forward), not just
BUILD_PLUGIN.md's prose -- the doc never nailed down the exact call shape,
so this was guessed wrong in an earlier version. It is now:

Aulthium invokes `entry` with the triggering text as ONE shell-quoted
argv argument (`entry "$text"`), in exactly two situations:

  1. A real web_search hook call -- the text is the search query.
  2. A "<prefix>> ..." chat-prompt forward (added to aulthium.sh
     alongside this plugin) -- the text is whatever followed the prefix,
     e.g. "use my-skill" for `skills> use my-skill`.

Aulthium does not tell these apart before calling entry -- both arrive
identically, as a single argv string. This script tells them apart
itself: if the first word of that string is one of this plugin's own
subcommands (list/add/remove/import/set/use/test), it's dispatched as a
command; otherwise the whole string is treated as a real search query
for the hook logic. A plain shell invocation with normal, separately
quoted argv words (`python3 skills_hook.py list`) works the same way,
since both shapes get rejoined into one string before that check.

Exit status matters: for hook (query) calls, printing the matched
skill and exiting 0 makes Aulthium use it as the search result; printing
nothing and exiting non-zero makes Aulthium fall through to a real web
search. Management/`use` commands just print plain text -- there's no
JSON anywhere in this protocol.

Known tradeoff: a search query that happens to start with exactly one
of this plugin's subcommand words ("list ...", "use ...") will be
misread as a command instead of a query. Not fixable from this script's
side without Aulthium tagging the two call sites differently.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


# ---------------------------------------------------------------- shared

def default_skills_dir():
    return os.environ.get("AULTHIUM_PLUGIN_CFG_SKILLS_DIR", "~/.aulthium/skills")


def parse_frontmatter(text):
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", text, re.DOTALL)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            key, val = line.split(":", 1)
            meta[key.strip()] = val.strip()
    return meta, m.group(2)


def render_frontmatter(meta, body):
    front = "\n".join(f"{k}: {v}" for k, v in meta.items())
    return f"---\n{front}\n---\n{body}"


def load_skills(skills_dir):
    skills = []
    root = Path(skills_dir).expanduser()
    if not root.is_dir():
        return skills
    for entry in sorted(root.iterdir()):
        skill_file = entry / "SKILL.md"
        if entry.is_dir() and skill_file.is_file():
            text = skill_file.read_text(encoding="utf-8", errors="replace")
            meta, body = parse_frontmatter(text)
            skills.append({
                "name": meta.get("name", entry.name),
                "description": meta.get("description", ""),
                "path": str(skill_file),
                "dir": str(entry),
                "full_text": text,
                "body": body,
            })
    return skills


def score(query, skill):
    q_words = set(re.findall(r"[a-z0-9]+", query.lower()))
    s_words = set(re.findall(r"[a-z0-9]+", (skill["name"] + " " + skill["description"]).lower()))
    if not q_words or not s_words:
        return 0
    return len(q_words & s_words)


# ----------------------------------------------------------------- hook

def run_hook(query):
    """Real web_search hook behavior: print + exit 0 to supply a result,
    print nothing + exit non-zero to decline and let the real search run."""
    skills_dir = default_skills_dir()
    threshold = int(os.environ.get("AULTHIUM_PLUGIN_CFG_MIN_SCORE", "2"))

    skills = load_skills(skills_dir)
    if not query or not skills:
        sys.exit(1)

    best, best_score = None, 0
    for skill in skills:
        s = score(query, skill)
        if s > best_score:
            best, best_score = skill, s

    if best and best_score >= threshold:
        print(f"[skill: {best['name']}] matched (score {best_score}) "
              f"instead of a live web search.\n")
        print(best["full_text"])
        sys.exit(0)
    else:
        sys.exit(1)


# -------------------------------------------------------------- CLI: list

def cmd_list(args):
    skills = load_skills(args.skills_dir)
    if not skills:
        print(f"No skills in {Path(args.skills_dir).expanduser()}")
        return
    for s in skills:
        print(f"{s['name']}")
        print(f"    {s['description']}")
        print(f"    {s['path']}")


# --------------------------------------------------------------- CLI: add

def cmd_add(args):
    root = Path(args.skills_dir).expanduser()
    target = root / args.name
    if target.exists() and not args.force:
        sys.exit(f"error: skill '{args.name}' already exists at {target} (use --force)")
    target.mkdir(parents=True, exist_ok=True)
    body = args.body if args.body else "(write the skill's instructions/reference content here)"
    text = render_frontmatter({"name": args.name, "description": args.desc}, f"\n\n{body}\n")
    (target / "SKILL.md").write_text(text)
    print(f"created {target / 'SKILL.md'}")


# ------------------------------------------------------------ CLI: remove

def cmd_remove(args):
    root = Path(args.skills_dir).expanduser()
    target = root / args.name
    if not target.is_dir():
        sys.exit(f"error: no skill named '{args.name}' in {root}")
    if not args.yes:
        resp = input(f"Remove skill '{args.name}' at {target}? [y/N] ").strip().lower()
        if resp != "y":
            print("aborted")
            return
    shutil.rmtree(target)
    print(f"removed {target}")


# ------------------------------------------------------------ CLI: import

def _install_skill_dir(skill_dir, root, force, rename=None):
    meta, _ = parse_frontmatter((skill_dir / "SKILL.md").read_text())
    name = rename or meta.get("name") or skill_dir.name
    dest = root / name
    if dest.exists():
        if not force:
            sys.exit(f"error: skill '{name}' already exists (use --force to overwrite)")
        shutil.rmtree(dest)
    shutil.copytree(skill_dir, dest)
    print(f"imported skill '{name}' -> {dest}")


def cmd_import(args):
    src = Path(args.source).expanduser()
    root = Path(args.skills_dir).expanduser()
    root.mkdir(parents=True, exist_ok=True)

    if src.is_file() and src.suffix == ".zip":
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(src) as zf:
                zf.extractall(tmp)
            found = list(Path(tmp).rglob("SKILL.md"))
            if not found:
                sys.exit("error: no SKILL.md found inside that zip")
            _install_skill_dir(found[0].parent, root, args.force, args.name)

    elif src.is_dir():
        if not (src / "SKILL.md").is_file():
            sys.exit(f"error: {src} has no SKILL.md")
        _install_skill_dir(src, root, args.force, args.name)

    elif src.is_file() and src.name == "SKILL.md":
        meta, _ = parse_frontmatter(src.read_text())
        name = args.name or meta.get("name")
        if not name:
            sys.exit("error: SKILL.md has no `name:` in its frontmatter -- pass --name")
        dest = root / name
        if dest.exists() and not args.force:
            sys.exit(f"error: skill '{name}' already exists (use --force)")
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, dest / "SKILL.md")
        print(f"imported skill '{name}' -> {dest}")

    else:
        sys.exit(f"error: {src} is not a SKILL.md file, a skill folder, or a .zip")


# --------------------------------------------------------------- CLI: set

def cmd_set(args):
    root = Path(args.skills_dir).expanduser()
    skill_md = root / args.name / "SKILL.md"
    if not skill_md.is_file():
        sys.exit(f"error: no skill named '{args.name}'")
    meta, body = parse_frontmatter(skill_md.read_text())
    meta[args.key] = args.value
    skill_md.write_text(render_frontmatter(meta, body))
    print(f"set {args.key} for '{args.name}'")


# --------------------------------------------------------------- CLI: use

def cmd_use(args):
    skills = {s["name"]: s for s in load_skills(args.skills_dir)}
    skill = skills.get(args.name)
    if not skill:
        sys.exit(f"error: no skill named '{args.name}' in {Path(args.skills_dir).expanduser()}")
    if args.json:
        print(json.dumps({"name": skill["name"], "description": skill["description"], "body": skill["body"]}))
    elif args.body_only:
        print(skill["body"].strip())
    else:
        print(skill["full_text"].strip())


# -------------------------------------------------------------- CLI: test

def cmd_test(args):
    skills = load_skills(args.skills_dir)
    if not skills:
        print(f"No skills in {Path(args.skills_dir).expanduser()}")
        return
    ranked = sorted(((score(args.query, s), s) for s in skills), key=lambda x: -x[0])
    for sc, s in ranked[:5]:
        print(f"{sc:>3}  {s['name']:<24} {s['description']}")


# ------------------------------------------------------------------ main

def build_parser():
    p = argparse.ArgumentParser(prog="skills_hook.py")
    p.add_argument("--skills-dir", default=default_skills_dir())
    sub = p.add_subparsers(dest="command")

    sp = sub.add_parser("list", help="list installed skills")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("add", help="scaffold a new skill")
    sp.add_argument("name")
    sp.add_argument("--desc", required=True)
    sp.add_argument("--body", default=None)
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_add)

    sp = sub.add_parser("remove", help="delete a skill")
    sp.add_argument("name")
    sp.add_argument("-y", "--yes", action="store_true", help="skip confirmation")
    sp.set_defaults(func=cmd_remove)

    sp = sub.add_parser("import", help="import a skill from a folder, SKILL.md, or .zip")
    sp.add_argument("source")
    sp.add_argument("--name", default=None, help="override the imported skill's name")
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_import)

    sp = sub.add_parser("set", help="change one frontmatter field of an existing skill")
    sp.add_argument("name")
    sp.add_argument("key")
    sp.add_argument("value")
    sp.set_defaults(func=cmd_set)

    sp = sub.add_parser("use", help="print a skill's content on demand (manual invocation)")
    sp.add_argument("name")
    sp.add_argument("--body-only", action="store_true", help="omit the --- frontmatter block")
    sp.add_argument("--json", action="store_true", help="emit {name, description, body} as JSON instead")
    sp.set_defaults(func=cmd_use)

    sp = sub.add_parser("test", help="show which skills a query would match, ranked")
    sp.add_argument("query")
    sp.set_defaults(func=cmd_test)

    return p


KNOWN_COMMANDS = {"list", "add", "remove", "import", "set", "use", "test"}


def main():
    argv = sys.argv[1:]
    if not argv:
        build_parser().print_help()
        sys.exit(1)

    # Rejoin whatever we got into one string. If Aulthium called us (hook
    # query, or a "<prefix>> ..." forward), argv is already exactly one
    # element and this is a no-op. If a human ran us from a real shell
    # with separately quoted words, this reconstructs the same text --
    # safe either way since the only thing that matters past this point
    # is the first word.
    full_text = " ".join(argv)
    first_word = full_text.split(None, 1)[0] if full_text.strip() else ""

    if first_word in KNOWN_COMMANDS or first_word in ("-h", "--help"):
        try:
            parsed_args = shlex.split(full_text)
        except ValueError:
            parsed_args = full_text.split()
        parser = build_parser()
        args = parser.parse_args(parsed_args)
        if not getattr(args, "func", None):
            parser.print_help()
            sys.exit(1)
        args.func(args)
    else:
        run_hook(full_text)


if __name__ == "__main__":
    main()
