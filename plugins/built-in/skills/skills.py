#!/usr/bin/env python3
"""
Aulthium hook plugin: "skills"

Verified against aulthium.sh's actual source (chat_pre_plugin_hook,
plugin_hook_call, and handle_repl_input / plugin_toggle_prefix_forward),
not just BUILD_PLUGIN.md's prose -- the doc never nailed down the exact
call shapes, so earlier versions of this file guessed some of them
wrong. It is now:

This plugin hooks "chat_pre" (see plugin.json), not "web_search". That
matters: web_search only fires when the model itself decides to call a
search tool, so a skill would sit unused on most ordinary requests
("write me a report") that never trigger a search. chat_pre fires on
EVERY user message before it's added to history and sent to the model,
which is what actually mirrors Claude's own behavior of checking for a
relevant SKILL.md before starting a task, not just when searching.

Two distinct, differently-shaped calls reach this script's entry:

  1. A real chat_pre hook call, via aulthium's generic plugin_hook_call:
     `entry chat_pre "$message"` -- TWO separate, individually
     shell-quoted argv elements, literal "chat_pre" first, the actual
     chat message second. This is the live per-message hook.
  2. A "<prefix>> ..." chat-prompt forward (plugin_toggle_prefix_forward)
     -- the text is whatever followed the prefix, e.g. "use my-skill"
     for `skills> use my-skill`, arriving as ONE shell-quoted argv
     string. Used for this plugin's own management subcommands, and
     also doubles as a manual way to preview what chat_pre would inject
     for arbitrary text (`skills> summarize this contract` behaves the
     same as that text arriving as a real chat message).

main() tells these apart by shape: literal argv == ["chat_pre", <msg>]
is case 1. Otherwise, if the first word is one of this plugin's own
subcommands (list/add/remove/import/set/use/test), it's dispatched as a
command; anything else is treated as chat_pre-style text to match
against, the same code path case 1 uses. A plain shell invocation with
normal, separately-quoted argv words (`python3 skills.py list`) is
handled without rejoining+reshlexing it (that would silently mangle any
argument containing spaces, e.g. `add name --desc "multi word desc"`);
only a genuine single-argv-string call gets split.

Exit status matters for the hook path: chat_pre's contract is "exit 0 +
non-empty stdout REPLACES the message for the rest of the chain (and
what the model ultimately sees)", so a match prints the matched
skill(s)' content FOLLOWED BY the user's original, untouched message --
never just the skill content alone, or the user's actual words would be
lost from what the model receives. No match: print nothing, exit
non-zero, so aulthium leaves the message exactly as typed. Management
commands (list/add/use/...) just print plain text -- there's no JSON
anywhere in this protocol except `use --json`.

Known tradeoff: chat text that happens to start with exactly one of
this plugin's subcommand words ("list restaurants nearby...") will be
misread as a command instead of chat text, when going through the
prefix-forward path. This does NOT affect the real chat_pre hook call
(case 1 above), which is tagged unambiguously by aulthium itself.

v0.3.0: switched from the "web_search" hook to "chat_pre" (see above)
-- this is the behavior change that makes skill matching actually run
on every message instead of only when the model chooses to search.
run_hook was renamed run_chat_pre_hook and now replaces the message
(skill content + original text) rather than standing in as a fake
search result.

v0.2.0: hook matching now works the way Claude itself scans skills --
several SKILL.md files can plausibly apply to one query, so matching no
longer stops at the single best scorer. Every skill clearing min_score
is returned, best first, capped at max_skills (config key, default 3)
so a vague query doesn't dump the whole library into the chat.
`skills> use` takes one or more names for the same reason (`use docx
frontend-design`), joining their content with a "---" separator; the
old single-name --json shape ({..}) is preserved for one name, and
only becomes a [..] array when more than one name is given.
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

def find_matches(query, skills_dir=None, threshold=None, max_skills=None):
    """Shared matching logic: every skill scoring >= threshold against
    query, ranked best first, capped at max_skills. Mirrors Claude
    scanning multiple plausibly-relevant SKILL.md files for one task
    rather than picking a single winner."""
    skills_dir = skills_dir if skills_dir is not None else default_skills_dir()
    if threshold is None:
        threshold = int(os.environ.get("AULTHIUM_PLUGIN_CFG_MIN_SCORE", "2"))
    if max_skills is None:
        max_skills = int(os.environ.get("AULTHIUM_PLUGIN_CFG_MAX_SKILLS", "3"))

    skills = load_skills(skills_dir)
    if not query or not skills:
        return []

    scored = [(score(query, skill), skill) for skill in skills]
    return sorted(
        (pair for pair in scored if pair[0] >= threshold),
        key=lambda pair: pair[0],
        reverse=True,
    )[:max_skills]


def run_chat_pre_hook(message):
    """chat_pre hook: runs on every user message before aulthium adds it
    to history and sends it to the model -- this is what makes skill
    matching happen on ordinary requests, not just when the model
    decides to search the web.

    Per chat_pre's contract, non-empty stdout + exit 0 REPLACES the
    message for the rest of the plugin chain and (unless a later plugin
    changes it further) is what the model actually sees and what gets
    stored in history. So a match must include the user's original text,
    not just the skill content -- otherwise the user's actual request
    would be silently dropped. No match: print nothing, exit non-zero,
    so aulthium leaves the message exactly as the user typed it.
    """
    matches = find_matches(message)
    if not matches:
        sys.exit(1)

    parts = [
        f"[skills plugin] {len(matches)} skill(s) matched this request "
        "and should guide the response, most relevant first:\n"
    ]
    for s, skill in matches:
        parts.append(f"--- skill: {skill['name']} (score {s}) ---\n"
                      f"{skill['full_text'].strip()}\n")
    parts.append("--- end of matched skills ---\n")
    parts.append(message)

    print("\n".join(parts))
    sys.exit(0)


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
    missing = [n for n in args.names if n not in skills]
    if missing:
        sys.exit(f"error: no skill named '{missing[0]}' in {Path(args.skills_dir).expanduser()}")

    selected = [skills[n] for n in args.names]

    if args.json:
        payload = [{"name": s["name"], "description": s["description"], "body": s["body"]} for s in selected]
        # Single name keeps the old {..} shape so existing callers parsing
        # `use one-name --json` don't have to change; multiple names get a
        # JSON array instead of silently only returning the first one.
        print(json.dumps(payload[0] if len(payload) == 1 else payload))
    elif args.body_only:
        print("\n\n---\n\n".join(s["body"].strip() for s in selected))
    else:
        print("\n\n---\n\n".join(s["full_text"].strip() for s in selected))


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

    sp = sub.add_parser("use", help="print one or more skills' content on demand (manual invocation)")
    sp.add_argument("names", nargs="+", metavar="name",
                     help="one or more skill names, e.g. 'use docx' or 'use docx frontend-design'")
    sp.add_argument("--body-only", action="store_true", help="omit the --- frontmatter block")
    sp.add_argument("--json", action="store_true",
                     help="emit {name, description, body} as JSON (an array when more than one name is given)")
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

    # Real chat_pre hook calls arrive as EXACTLY two argv elements, via
    # aulthium's generic plugin_hook_call: literal "chat_pre" first, the
    # actual chat message second. Peel this off before anything else --
    # "chat_pre" isn't one of this plugin's own subcommands, so without
    # this check it would fall into the generic dispatch below and get
    # misread as chat text starting with the word "chat_pre".
    if len(argv) == 2 and argv[0] == "chat_pre":
        run_chat_pre_hook(argv[1])
        return

    # Two distinct remaining calling conventions land here, and they
    # can't be handled the same way:
    #
    #   1. Aulthium's prefix-forward convention: `entry "$text"` -- the
    #      ENTIRE rest arrives as exactly one already-shell-quoted argv
    #      element (a "<prefix>> ..." forward). That one string still
    #      needs to be split into words ourselves.
    #   2. A human running it from a real shell with normal, separately
    #      quoted words: `skills.py add name --desc "multi word desc"`.
    #      argv is already correctly tokenized by the shell here -- re-
    #      joining with spaces and re-splitting (the old approach) throws
    #      that quoting away and mangles any word containing a space, so
    #      this path must NOT rejoin/reshlex argv.
    #
    # Only the single-argv-element case needs splitting; multi-element
    # argv is used as-is.
    if len(argv) == 1:
        full_text = argv[0]
        first_word = full_text.split(None, 1)[0] if full_text.strip() else ""
        if first_word in KNOWN_COMMANDS or first_word in ("-h", "--help"):
            try:
                parsed_args = shlex.split(full_text)
            except ValueError:
                parsed_args = full_text.split()
        else:
            # Not a subcommand -- treat as chat_pre-style text to match
            # against, same as the real hook path above. This lets
            # `skills> summarize this contract` preview exactly what
            # would get injected if that text arrived as a real message.
            run_chat_pre_hook(full_text)
            return
    else:
        first_word = argv[0]
        if first_word in KNOWN_COMMANDS or first_word in ("-h", "--help"):
            parsed_args = argv
        else:
            run_chat_pre_hook(" ".join(argv))
            return

    parser = build_parser()
    args = parser.parse_args(parsed_args)
    if not getattr(args, "func", None):
        parser.print_help()
        sys.exit(1)
    args.func(args)


if __name__ == "__main__":
    main()
