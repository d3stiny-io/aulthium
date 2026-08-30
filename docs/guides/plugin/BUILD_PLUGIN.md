# Building an Aulthium plugin

A plugin is just a folder with a manifest and a program in it. Aulthium
doesn't sandbox plugins the way it sandboxes the file agent — running one
is a trust decision (same tier as approving a shell command), gated by a
y/N confirmation. In exchange, a plugin gets to be a completely normal,
independent program in whatever language you want: it isn't limited to
the marker-based protocol the in-chat file/shell agent uses.

## Where plugins live

```
~/.aulthium/plugins/<your-plugin-name>/
  plugin.json      ← manifest (required)
  ...anything else your plugin needs
```

(Override the base folder with the `AULTHIUM_PLUGINS_DIR` env var.)

## The manifest — `plugin.json`

```json
{
  "name": "plugin-name",
  "description": "One short sentence describing what it does",
  "version": "1.0.0",
  "entry": "python3 myplugin.py",
  "runtime": "python3",
  "mode": "foreground",
  "permissions": ["network"],
  "config": { "timeout": "30" }
}
```

| field           | required | meaning                                                                 |
|-----------------|----------|--------------------------------------------------------------------------|
| `name`          | yes      | must match the folder name; letters/numbers/`-`/`_` only                |
| `description`   | yes      | shown in `t> plugin list` and `t> plugin info`                          |
| `entry`         | yes*     | the shell command Aulthium runs, from inside your plugin's own folder (*not required to install, but the plugin can't be run without one) |
| `runtime`       | no       | a command Aulthium checks exists before running `entry` (e.g. `python3`, `node`); skip this if `entry` needs nothing special |
| `version`       | no       | free-form string, informational only                                    |
| `mode`          | no       | `"foreground"` (default) or `"hook"` — see [Foreground vs. hook plugins](#foreground-vs-hook-plugins) |
| `hook`          | if `mode` is `hook` | which hook point to register at — one of `web_search`, `chat_pre`, `shell_exec`, `file_action`, `mcp_call`; see [Hook points and their call conventions](#hook-points-and-their-call-conventions) |
| `toggle_prefix` | no       | hook mode only — lets `<prefix>> on`/`<prefix>> off` toggle it from the normal chat prompt |
| `autostart`     | no       | hook mode only — `true` to launch it automatically every time Aulthium starts |
| `priority`      | no       | hook mode only — integer, default `0`; when more than one plugin shares a hook point, higher runs earlier in the chain (ties keep insertion order) — see [Multiple plugins on one hook point](#multiple-plugins-on-one-hook-point) |
| `permissions`   | no       | array of scopes this plugin needs — see [Permissions](#permissions) |
| `config`        | no       | object of default config keys/values — see [Config defaults and overrides](#config-defaults-and-overrides) |

`entry` can be anything runnable from a shell: `python3 webchat.py`,
`node server.js`, `./run.sh`, a compiled binary, etc. Aulthium runs it with
`eval`, `cd`'d into your plugin's folder, so relative paths inside your
entry command work as expected.

## Foreground vs. hook plugins

Most plugins are **foreground**: `t> plugin run <name>` takes over the
terminal until the program exits (or you Ctrl+C out of it), then control
returns to the normal chat prompt. This is the default if `mode` is
omitted.

A **hook** plugin (`"mode": "hook"`) is different: `t> plugin run <name>`
doesn't take over anything — it just registers the plugin against a named
hook point (declared in `"hook"`, e.g. `"web_search"`) and hands control
straight back to the `User>` prompt. From then on, Aulthium calls the
plugin automatically whenever that hook point fires, on-demand, per call —
it never runs continuously as a background process.

If you set a `toggle_prefix` (e.g. `"bws"`), the user can flip the plugin
on/off from the ordinary chat prompt with `bws> on` / `bws> off`, without
touching `t> plugin toggle`. Setting `"autostart": true` makes it register
itself again automatically on every future launch, until explicitly
stopped with `t> plugin run --stoprun <name>`.

### Hook points and their call conventions

There are five hook points, and **they do not all call your `entry`
command the same way** — get this wrong and your plugin will silently
misread its own arguments. `web_search` is the odd one out: it's the
original hook point and predates the others, so it invokes `entry`
directly with just the query, no hook-name argument in front. Every
other hook point goes through a shared internal call path that always
puts the hook's own name first, then its specific arguments after —
so your entry script always knows which hook point a given call is for
by looking at `argv[1]` (or `sys.argv[1]` in Python).

| hook point    | call shape                              | argc | chain behavior |
|---------------|------------------------------------------|------|-----------------|
| `web_search`  | `entry "$query"`                          | 1    | fallback — tries each plugin in turn, stops at the first one that returns a result |
| `chat_pre`    | `entry chat_pre "$message"`               | 2    | transform — every active plugin runs, in order, each seeing the previous one's rewrite |
| `shell_exec`  | `entry shell_exec "$command"`             | 2    | veto/transform — every active plugin runs, in order; any one can veto and stop the chain, or rewrite the command for the rest of the chain |
| `file_action` | `entry file_action "$action" "$path"`     | 3    | veto — every active plugin runs, in order; any one can veto and stop the chain (`$action` is one of `write`/`edit`/`create-folder`/`delete-file`/`delete-folder`) |
| `mcp_call`    | `entry mcp_call "$server" "$tool" "$args_json"` | 4 | veto/transform — same as `shell_exec`, but a replacement must be valid JSON or it's discarded with a warning |

Only one hook point can fire per `entry` invocation — Aulthium never
sends you two hook calls merged into one. If more than one plugin is
registered on the *same* hook point, see
[Multiple plugins on one hook point](#multiple-plugins-on-one-hook-point)
below for how the chain works.

#### `web_search`

```python
import sys
query = sys.argv[1]   # the whole query, already de-quoted by the shell
...
print(result_text)    # becomes the search result
# or, to decline and let the real search run:
# sys.exit(1)
```

Whatever your program prints to stdout is used as the result verbatim
if it exits 0 with non-empty output; a nonzero exit or empty stdout
means "I don't have anything for this," and Aulthium falls through to
its normal search providers instead (so a plugin that doesn't want to
handle a particular query should just print nothing and exit non-zero,
rather than treating that as an error).

#### `chat_pre`

Fires on **every** user message, right before it's added to conversation
history and sent to the model — the only hook point that runs on
ordinary chat traffic rather than a specific action the user or model
triggered. Useful for rewriting or augmenting what the model actually
sees (a local knowledge base, a house style rewrite, injected context)
without the user having to ask for it every time.

```python
import sys
# sys.argv == ["chat_pre", "<the user's message>"]
message = sys.argv[2]
...
print(new_message_text)   # REPLACES the message for the rest of the
                            # chain, and (if nothing later changes it
                            # further) what the model and history get
sys.exit(0)
# or, to leave the message untouched:
# sys.exit(1)   # (or exit 0 with empty stdout)
```

If you want to *add* to the message rather than replace it outright —
the common case — make sure your replacement still includes the
original text somewhere in it; printing only your added content
silently discards whatever the user typed.

#### `shell_exec`

Fires once, right before the user is asked to confirm a pending shell
command.

```python
import sys
# sys.argv == ["shell_exec", "<the pending command>"]
cmd = sys.argv[2]
...
print("VETO:command touches /etc, blocking")   # blocks it; rest of the
                                                  # line is shown as the reason
# or:
print(rewritten_cmd)   # replaces the command for the rest of the chain
                        # and (if unchanged further) the confirmation box
# or, to leave it as-is:
# sys.exit(1)   # (or exit 0 with empty stdout)
```

#### `file_action`

Fires once per single-item file mutation (write/edit/create-folder/
delete-file/delete-folder), before the user is asked to confirm it.
**Bulk** write/create/delete/move, `FILE_MOVE`/`FOLDER_MOVE`, and
`ZIP_CREATE`/`ZIP_EXTRACT` are *not* currently routed through this hook.

```python
import sys
# sys.argv == ["file_action", "<action>", "<path>"]
action, path = sys.argv[1], sys.argv[2]
...
sys.exit(0)   # allow
# or:
print("touches a path outside the expected project root")
sys.exit(1)   # veto — your stdout becomes the shown reason
```

Unlike the other hooks, there's no "replace" concept here — a plugin
either allows (exit 0) or vetoes (non-zero exit, with the reason on
stdout) a single pending action. There's no built-in review behavior to
fall back to, so an active chain with nothing registered, or everyone
allowing, is what lets ordinary file actions through.

#### `mcp_call`

Fires once per pending MCP tool call, before the user is asked to
confirm it.

```python
import sys, json
# sys.argv == ["mcp_call", "<server>", "<tool>", "<args-json>"]
server, tool, args_json = sys.argv[1], sys.argv[2], sys.argv[3]
...
print("VETO:not an approved server")   # blocks it
# or:
print(json.dumps(new_args))   # replaces the arguments for the rest of
                                # the chain — must be valid JSON, or
                                # it's discarded (with a warning) rather
                                # than sent on
# or, to leave the arguments as-is:
# sys.exit(1)   # (or exit 0 with empty stdout)
```

### Multiple plugins on one hook point

Any number of plugins can register on the same hook point — there's no
single "owner" the way there might be in a simpler plugin system. What
"multiple plugins on one point" *means* differs by hook, matching the
chain-behavior column in the table above:

- **`web_search`** is a fallback chain: Aulthium calls each active
  plugin in turn and stops at the first one that returns a real result,
  falling through to its normal search providers only if every plugin
  in the chain declines.
- **`shell_exec`, `file_action`, `mcp_call`** are veto (review) chains:
  every active plugin gets a look, in order, and any single one can
  veto and stop the chain right there; `shell_exec`/`mcp_call` also let
  a plugin rewrite the command/arguments for whichever plugins run
  after it.
- **`chat_pre`** is a transform chain: every active plugin runs, in
  order, and each one sees whatever the previous plugin left the
  message as — so a rewrite from an earlier plugin is visible to (and
  can be further changed by) a later one.

Order within a chain is decided by each plugin's `priority` (higher
runs earlier; default `0`; ties keep insertion order) — see the
manifest table above. A plugin that's registered but currently toggled
`off` is skipped entirely; an empty or fully-toggled-off chain means
every `*_plugin_hook` wrapper falls back to its built-in behavior
(a real web search, the action goes through unmodified, etc.).

### Prefix commands beyond on/off

Anything typed after `<prefix>>` that *isn't* literally `on` or `off` is
forwarded straight to your `entry` command, and whatever your program
prints to stdout is shown back in the chat as-is. Aulthium doesn't parse
or understand this text at all — your entry script decides what it
means.

**This call shape is always the same regardless of which hook point
your plugin is registered on**: the trailing text goes in as **one**
shell-quoted argv argument, full stop — `entry "$rest"`. It does *not*
follow whatever convention your hook point normally uses.

```
skills> use my-skill        # -> entry gets invoked as: entry "use my-skill"
```

For a plugin registered on `web_search` this happens to look identical
to a real hook call (both are exactly one argv argument), which is why
the two need to be told apart by content, not shape — e.g. checking
whether the text starts with a subcommand word your plugin recognizes.

For a plugin registered on any *other* hook point, the shapes are
already different and distinguishable on sight: a real `chat_pre` call
arrives as `entry chat_pre "<message>"` (**two** argv arguments, literal
`chat_pre` first — see [Hook points and their call
conventions](#hook-points-and-their-call-conventions)), while a
`skills> ...` prefix forward always arrives as a single argument with no
hook name in front of it. Check `len(sys.argv)` (or `argc`) and whether
`sys.argv[1]` is literally your hook's name before assuming which kind
of call you're handling.

This only fires while the plugin is toggled **on** — `<prefix>> off`
blocks it too, same as it blocks the hook point itself.

## Permissions

Aulthium doesn't sandbox a plugin — declaring permissions is purely
informational, so the person running your plugin knows what it's asking
for before they grant it. The known scopes:

| scope        | meaning                                                                 |
|--------------|--------------------------------------------------------------------------|
| `network`    | makes its own HTTP requests, beyond the AI API call itself             |
| `filesystem` | reads/writes files outside the sandboxed workspace                     |
| `shell`      | runs arbitrary commands on the machine                                 |
| `mcp`        | calls the user's connected MCP servers/tools                           |
| `secrets`    | receives the live API key for the active provider                      |

Every `t> plugin run <name>` shows the declared permission set and asks
for an explicit y/N grant — this is separate from `t> confirm off`, which
only covers in-chat file/shell/MCP agent actions, never a plugin's grant.
The grant is remembered by name, but only for as long as the exact
permission set stays the same: change `"permissions"` in a later update
and the user is re-prompted, rather than silently inheriting an old
approval.

## Config defaults and overrides

`"config"` in `plugin.json` declares your plugin's defaults. A user can
override any key locally without touching your manifest:

```
t> plugin config <name> list                     # see effective config (defaults + overrides)
t> plugin config <name> set <key> <value>
t> plugin config <name> get <key>
t> plugin config <name> unset <key>
```

Overrides live in a separate `config.json` next to `plugin.json` inside
the plugin's folder, so they survive `t> plugin update`/reinstall
untouched. Your plugin receives the effective (merged) result at launch —
see `AULTHIUM_PLUGIN_CONFIG_JSON` / `AULTHIUM_PLUGIN_CFG_<KEY>` below.

## Installing it

```
t> plugin install /path/to/your-plugin-folder
```

This copies the folder into `~/.aulthium/plugins/<name>/` (name comes
from the manifest, not the source folder's name). Then:

```
t> plugin list             # see it
t> plugin info <name>      # see the full manifest, effective config, and integrity status
t> plugin run <name>       # launch it (asks for y/N confirmation first)
t> plugin toggle <name> <on|off>   # hook plugins only — flip without stopping
t> plugin update [name]    # check GitHub-sourced plugins for a newer version
t> plugin remove <name>    # delete an installed plugin (asks for confirmation)
```

Anything after the name on `t> plugin run <name> ...` is passed straight
through as extra arguments to your `entry` command.

## Integrity fingerprint and `t> plugin verify`

Every install/update stamps an `_integrity` block into `plugin.json` — a
SHA-256 hash of every other file in the plugin's folder (nothing outside
it, and not `plugin.json` or `config.json` themselves), plus a UTC
timestamp:

```json
"_integrity": { "sha256": "…", "at": "2026-08-29T02:03:43Z" }
```

`t> plugin verify <name>` recomputes that hash right now and compares it
to what's recorded — a strictly read-only check that never repairs or
re-stamps anything. `t> plugin run` also checks this automatically and
warns (non-fatally — you're allowed to edit your own plugin) if the files
have drifted since the hash was last recorded. Getting a fresh, honest
hash is the only way this ever reports a match — there's no supported way
to make a changed plugin verify clean without actually reinstalling or
otherwise re-stamping it, since that would defeat the point of having a
fingerprint at all.

## Scaffolding a new plugin

There's no in-chat wizard for this — scaffolding lives in a separate,
standalone script you run directly with bash, outside the Aulthium REPL:

```
./aulthium-plugin-create.sh <name> [flags...]
```

It writes the same `plugin.json` / entry-script / README shape described
above straight into `$PLUGINS_DIR`, so the result is immediately usable
from `t> plugin list` / `t> plugin run <name>` / `t> plugin verify <name>`
— no separate `t> plugin install` step needed for something scaffolded
this way. Useful flags:

```
--desc "<text>"            short description (may contain spaces)
--version <x.y.z>          default: 0.1.0
--mode foreground|hook     default: foreground
--hook <point>             required for --mode hook; default: web_search
                           (one of web_search/chat_pre/shell_exec/file_action/mcp_call)
--toggle-prefix <p>        hook-mode shorthand, e.g. 'bws' for 'bws> on'
--autostart                hook-mode: launch automatically every start
--runtime bash|python3|node|none   default: bash
--perm <scope>             repeatable — network/filesystem/shell/mcp/secrets
--config <key>=<value>     repeatable — a config default
--force                    overwrite an existing plugin of the same name
--security-print           print the integrity hash right after creating
--verify                   immediately verify the new plugin's files
```

Example — scaffold a plugin with two permissions and a config default,
then print and confirm its fingerprint in the same command:

```
./aulthium-plugin-create.sh webhook-relay \
    --desc "Relays incoming webhooks to the active provider" \
    --runtime python3 --perm network --perm secrets \
    --config timeout=30 --security-print --verify
```

This only covers scaffolding. Everything else — installing from a
folder/zip/GitHub repo, running, toggling, configuring, updating,
removing — is still done from inside Aulthium with `t> plugin ...`, as
described above.

## What Aulthium hands your plugin

Right before launch, Aulthium exports these environment variables (then
unsets them again once your plugin exits):

| variable                    | meaning                                                                 |
|------------------------------|--------------------------------------------------------------------------|
| `AULTHIUM_API_KIND`          | `"openai"` or `"google"` — which request/response shape to speak       |
| `AULTHIUM_API_URL`           | endpoint to call — see the two shapes below                            |
| `AULTHIUM_API_KEY`           | the active provider's API key (may be empty for a keyless custom endpoint) |
| `AULTHIUM_MODEL`             | the currently selected model id                                        |
| `AULTHIUM_PROVIDER`          | internal provider id (`openrouter`, `google`, `mistral`, `huggingface`, `nvidia_nim`, `custom`) |
| `AULTHIUM_PROVIDER_LABEL`    | human-readable provider name, for display                              |
| `AULTHIUM_WORKSPACE_DIR`     | the user's current sandbox folder (informational — nothing stops you from touching more, but respect it as a hint of user intent) |
| `AULTHIUM_APP_NAME` / `AULTHIUM_APP_VERSION` | `"AULTHIUM"` and its version string                     |

Your plugin talks to the AI backend **directly** — it does not go back
through Aulthium's bash process. This means it works even after the
terminal session that launched it moves on to something else, and it's
why a plugin can be a real, independent program instead of a script tied
to the chat loop.

### If `AULTHIUM_API_KIND` is `"openai"`

This covers OpenRouter, Mistral, Hugging Face, NVIDIA NIM, and any
"Other" custom OpenAI-compatible endpoint — they all speak the same
`/chat/completions` shape.

```
POST $AULTHIUM_API_URL
Content-Type: application/json
Authorization: Bearer $AULTHIUM_API_KEY   (omit this header entirely if the key is empty)

{
  "model": "$AULTHIUM_MODEL",
  "messages": [{"role": "user", "content": "..."}, ...],
  "temperature": 0.7
}
```

Response: `.choices[0].message.content` is the reply text.

### If `AULTHIUM_API_KIND` is `"google"`

`AULTHIUM_API_URL` is the API **base** (currently
`https://generativelanguage.googleapis.com/v1beta`) — append the model
and an API-key query param yourself:

```
POST $AULTHIUM_API_URL/models/$AULTHIUM_MODEL:generateContent?key=$AULTHIUM_API_KEY
Content-Type: application/json

{
  "contents": [
    {"role": "user", "parts": [{"text": "..."}]},
    {"role": "model", "parts": [{"text": "..."}]}
  ],
  "systemInstruction": {"parts": [{"text": "..."}]}   (optional)
}
```

Response: join `.candidates[0].content.parts[].text` for the reply text.

Both shapes are implemented in full, working order in the bundled
`webchat` plugin (`~/.aulthium/plugins/webchat/webchat.py`) — the easiest
way to see either one end-to-end is to read that file.

## The built-in plugin: `webchat`

Ships pre-installed the first time Aulthium runs. It's a small,
dependency-free Python script (stdlib only — `http.server` +
`urllib.request`, no `pip install` needed) that starts a local web server
and opens a browser tab with a chat UI, wired to whatever provider/model
you currently have active. Handy if you'd rather click than type into a
terminal prompt, or want to hand the chat to someone who isn't
comfortable in a terminal at all.

```
t> plugin run webchat
```

It listens on `127.0.0.1` only (starting at port 8420, walking upward if
that's taken — override the start port with `AULTHIUM_WEBCHAT_PORT`), so
it's not reachable from outside your machine. Conversation history lives
in the browser tab's memory only — closing the tab clears it, same as
`t> reset` does for the terminal chat.

Delete `~/.aulthium/plugins/webchat/` and restart Aulthium to reset it
back to the bundled version if you've edited it and want the original
back.

## Writing your own

A minimal plugin needs nothing more than a manifest and one file. You can
write these by hand, or scaffold the skeleton in one command with the
standalone script (see [Scaffolding a new plugin](#scaffolding-a-new-plugin)
above):

```
./aulthium-plugin-create.sh hello --desc "Prints a one-off reply from the AI, non-interactively" --runtime python3
```

That writes `~/.aulthium/plugins/hello/plugin.json`, a `run.py` stub, and
a `README.md`. Or by hand:

```
~/.aulthium/plugins/hello/plugin.json
~/.aulthium/plugins/hello/hello.py
```

```json
{
  "name": "hello",
  "description": "Prints a one-off reply from the AI, non-interactively",
  "entry": "python3 hello.py",
  "runtime": "python3"
}
```

```python
import os, json, urllib.request

url = os.environ["AULTHIUM_API_URL"]
key = os.environ.get("AULTHIUM_API_KEY", "")
model = os.environ["AULTHIUM_MODEL"]

payload = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
}).encode()

headers = {"Content-Type": "application/json"}
if key:
    headers["Authorization"] = "Bearer " + key

req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
with urllib.request.urlopen(req) as resp:
    body = json.loads(resp.read())
print(body["choices"][0]["message"]["content"])
```

(This example assumes an `"openai"`-kind provider — check
`AULTHIUM_API_KIND` first if you want it to work with Google too, the
way `webchat.py` does.)

```
t> plugin install ~/.aulthium/plugins/hello    # or wherever you built it
t> plugin run hello
```

## Notes and limits

- Plugins are **not** confined to `AULTHIUM_WORKSPACE_DIR` or anything
  else — they run with your normal shell privileges, exactly like the
  shell agent's proposed commands. Only install and run plugins you
  trust, and treat a `t> plugin verify` mismatch as a reason to stop and
  look, not something to wave through.
- `t> plugin run` always asks for a y/N permissions confirmation before
  launching, regardless of `t> confirm off` (that toggle only covers the
  in-chat file/shell/MCP agent actions, not plugins).
- `t> plugin remove <name>` uninstalls a plugin (with confirmation); you
  can also just delete its folder under `~/.aulthium/plugins/` by hand.
