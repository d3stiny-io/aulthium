# skills — an Aulthium hook plugin

A `web_search`-hook plugin that gives Aulthium something like Claude's
skills: a folder of `SKILL.md` files (name + description + instructions),
matched against the query and used *instead of* a live search when one
fits well enough.

## What it does

1. Registers on the `web_search` hook point (`"mode": "hook"`).
2. On each call, reads the query and scans every `<skills_dir>/<skill>/SKILL.md`.
3. Scores each skill by keyword overlap between the query and that
   skill's `name` + `description` frontmatter.
4. If the best score clears `min_score`, prints that skill's full
   content and exits 0 — Aulthium uses it as the search result.
5. Otherwise prints nothing and exits non-zero, so Aulthium's normal
   `web_search` proceeds as usual.

## Requires a small aulthium.sh patch

`skills> use my-skill` only works if `aulthium.sh` itself has been
patched to forward unrecognized `<prefix>> ...` text to a plugin's
`entry` command — that's not something a plugin can add from inside its
own folder, since it's chat-prompt parsing done by the host script
before a plugin is ever invoked. A patched `aulthium.sh` (adds a
`plugin_toggle_prefix_forward` function and extends `handle_repl_input`)
ships alongside this plugin — replace your existing script with it, or
apply the same change by hand if you've customized yours.

The automatic hook (registered via `t> plugin run skills`) works either
way, patched or not — it's `skills> use ...` from the chat prompt
specifically that needs the patch. Without it, use the CLI form from a
real shell instead:

```
cd ~/.aulthium/plugins/skills
python3 skills_hook.py use my-skill
```

## Install

```
t> plugin install /path/to/skills-plugin
t> plugin run skills
```

You'll get the usual y/N permission prompt (this plugin only asks for
`filesystem`, to read the skills folder — no `network`, no `secrets`).

Since it's a hook plugin, `t> plugin run skills` just registers it and
hands control back to `User>` — it doesn't take over the terminal.
With `"autostart": true` in the manifest it re-registers on every future
launch; `t> plugin run --stoprun skills` stops that.

Because `"toggle_prefix": "skills"` is set, you can also flip it on/off
from the ordinary prompt:

```
skills> on
skills> off
```

## Add your own skills

Default skills folder: `~/.aulthium/skills/` (change it with
`t> plugin config skills set skills_dir <path>`). Each skill is a
subfolder with a `SKILL.md`:

```
~/.aulthium/skills/
  my-skill-name/
    SKILL.md
```

```markdown
---
name: my-skill-name
description: One sentence, specific — this is the only thing matched against queries.
---

Whatever instructions/reference content you want handed back when this
skill matches.
```

A copy of `skills/example-writing-style/` ships alongside this plugin —
copy it into your skills folder, rename it, and rewrite the frontmatter
and body to make a real skill.

## Using skills

There are two separate ways a skill's content actually reaches you —
don't confuse them:

**1. Automatic, via the hook.** Once the plugin is registered
(`t> plugin run skills`, or it's autostarted), *nothing further is
needed* — every time Aulthium's own `web_search` fires, this plugin
quietly checks the query against your skills first. If one scores above
`min_score`, its content is substituted for a live search result and
that's what the AI sees. You never type anything for this to happen;
it either fires or it doesn't, based on keyword overlap between the
query and the skill's `description`. Use `test` (below) to check
*whether* a given query would trigger a skill before relying on it live.

**2. Manual, via `use`.** Sometimes you know exactly which skill you
want, right now, regardless of whether a `web_search` is happening —
e.g. you're about to ask for a draft and want the writing-style skill's
rules in front of you (or pasted into the chat) first:

```
python3 skills_hook.py use my-skill                # frontmatter + body
python3 skills_hook.py use my-skill --body-only     # just the instructions
python3 skills_hook.py use my-skill --json          # {name, description, body}
```

This is a plain read — it doesn't touch the hook, doesn't require the
plugin to be running/registered, and doesn't consume a `web_search`
call. It just prints the skill so you can paste it into the chat
yourself or pipe it into something else (`--json` is meant for that:
`python3 skills_hook.py use my-skill --json | some-other-tool`).

Rule of thumb: if you want a skill applied *whenever it's relevant*,
rely on the hook and spend your effort tuning `description` fields.
If you want a *specific* skill applied *right now*, use `use`.

## Managing skills

`skills_hook.py` doubles as a management CLI when you run it directly
with arguments (bypassing the hook protocol entirely — this is you
calling the script from a shell, not Aulthium calling it):

```
cd ~/.aulthium/plugins/skills

python3 skills_hook.py list
python3 skills_hook.py add my-skill --desc "One sentence, specific"
python3 skills_hook.py remove my-skill              # asks y/N first
python3 skills_hook.py remove my-skill -y            # skip confirmation
python3 skills_hook.py import ./some-skill-folder
python3 skills_hook.py import ./SKILL.md --name my-skill
python3 skills_hook.py import ./bundle.zip           # any zip containing a SKILL.md
python3 skills_hook.py set my-skill description "New, sharper description"
python3 skills_hook.py test "how do I refactor this function"
```

All of these take `--skills-dir <path>` if you're not using the default
(`~/.aulthium/skills`, or whatever `t> plugin config skills set
skills_dir ...` has been set to).

- **add** scaffolds `<skills_dir>/<name>/SKILL.md` with the frontmatter
  filled in and a placeholder body for you to edit.
- **remove** deletes a skill's folder; prompts for confirmation unless
  you pass `-y`/`--yes`.
- **import** accepts a folder containing `SKILL.md`, a bare `SKILL.md`
  file, or a `.zip` with a `SKILL.md` anywhere inside it — the same
  three shapes you'd expect to receive a shared skill in. `--name`
  overrides whatever name is in the frontmatter; `--force` overwrites
  an existing skill of that name instead of refusing.
- **set** edits one frontmatter field in place (most often
  `description`, since that's the only thing matching uses).
- **test** doesn't touch anything — it ranks every skill against a
  query so you can tune descriptions before trusting the hook to pick
  the right one live.

## Config

```
t> plugin config skills list
t> plugin config skills set skills_dir /some/other/path
t> plugin config skills set min_score 3      # require a closer match
```

## The calling convention (verified against aulthium.sh's source)

An earlier version of this README guessed a JSON-on-stdin protocol.
That was wrong. The real thing, confirmed by reading
`web_search_query_plugin_hook` in `aulthium.sh`:

- Aulthium calls `entry` with the query as **one shell-quoted argv
  argument** (`entry "$query"`) — no JSON, no stdin.
- Your program's stdout is used as the search result **only if it
  exits 0 with non-empty output**. A non-zero exit (or empty stdout)
  tells Aulthium "not handled" and it falls through to a real search.

`skills> use my-skill` is not a documented Aulthium feature — the
stock `handle_repl_input` only recognizes `<prefix>> on` / `off`. Making
`use` work as shown above requires the small `aulthium.sh` patch that
ships alongside this plugin (see below); without it, only
`t> plugin run skills` (registration) and the automatic hook work —
`skills> use ...` would just fall through to `send_chat` and get sent
to the AI as a chat message instead.

## Matching logic

Deliberately simple: lowercase, tokenize on `[a-z0-9]+`, count overlap
between query words and (skill name + description) words, take the
highest-scoring skill above `min_score`. No embeddings, no external
calls — it's meant to be inspectable and easy to tune, not clever.
