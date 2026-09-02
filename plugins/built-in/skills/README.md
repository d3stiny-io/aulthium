# skills

Gives Aulthium a local library of Claude-style `SKILL.md` files, and
injects every skill that plausibly applies before each message reaches
the model — the same way Claude consults its own skills.

## What it does

This plugin hooks `chat_pre`, not `web_search`. That distinction matters:
`web_search` only fires when the model itself decides to call a search
tool, so a skill would sit unused on most ordinary requests ("write me a
report") that never trigger a search. `chat_pre` fires on **every** user
message before it's added to history and sent to the model — which
actually mirrors checking for a relevant `SKILL.md` before starting a
task, not just when searching.

On each message, it scores every skill in the library against the text
and injects the content of every skill that clears a minimum score (not
just the single best match), followed by the user's original, unmodified
message.

## Directory layout

Skills live under `skills_dir` (default `~/.aulthium/skills`), one folder
per skill, each containing a `SKILL.md` with YAML frontmatter:

```
~/.aulthium/skills/
  my-skill/
    SKILL.md
```

```markdown
---
name: my-skill
description: What this skill does and when it applies.
---

Instructions / reference content the model should follow when this
skill is relevant.
```

Skills are looked up and referenced by **slug** (the folder name), not
by the frontmatter `name:` field — the frontmatter name is just what's
displayed, and can be changed independently of the folder.

## Usage

Management commands, at the `skills>` prefix or via `python3 skills.py`:

```
skills> list                              # list installed skills
skills> add <name> --desc "..."           # scaffold a new skill
skills> remove <name>                     # delete a skill (asks to confirm)
skills> import <path-or-zip>              # install from a folder, SKILL.md, or .zip
skills> set <name> <key> <value>          # edit a skill's frontmatter
skills> use <name> [<name2> ...]          # print a skill's full content
skills> test "<query text>"               # preview which skills would match
```

`import` accepts a single `SKILL.md` file, a folder containing one, or a
`.zip` — including a zip bundling multiple skills, all of which are
installed. Add `--force` to overwrite an existing skill of the same name,
and `--name` to install under a different slug than the source provides.

`skills> test "<query>"` is the easiest way to check your matching
without waiting for a real chat message — it prints the top-scoring
skills and their scores.

Anything typed at the `skills>` prefix that isn't one of the subcommands
above (`list`/`add`/`remove`/`import`/`set`/`use`/`test`) is treated as
`chat_pre`-style text, letting you preview exactly what would get
injected for a real chat message.

## Configuration

Set with `t> plugin config skills set <key> <value>`:

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `skills_dir` | `~/.aulthium/skills` | Where skill folders live |
| `min_score` | `2` | Minimum match score for a skill to be injected |
| `max_skills` | `3` | Maximum number of skills injected per message |

Note: `min_score`, `max_skills`, and `skills_dir` are this plugin's own
settings and are changed via `plugin config`, not via `skills> set` (which
edits an individual *skill's* frontmatter). Trying to `use`/`remove`/`set`
one of these names as if it were a skill will point you at the correct
command instead of failing silently.

## Permissions

Declares `filesystem` in `plugin.json` — it reads and writes skill files
under `skills_dir`. It does not use the network or execute shell commands.

## Contributing a skill

If a workflow could be useful to other Aulthium users, consider
contributing it as a skill — see the main
[CONTRIBUTING.md](../../../CONTRIBUTING.md) for what makes a good skill
(clear purpose, reusable, easy to understand, no unnecessary instructions).
