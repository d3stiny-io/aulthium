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
  "runtime": "python3"
}
```

| field         | required | meaning                                                                 |
|---------------|----------|--------------------------------------------------------------------------|
| `name`        | yes      | must match the folder name; letters/numbers/`-`/`_` only                |
| `description` | yes      | shown in `t> plugin list` and `t> plugin info`                          |
| `entry`       | yes      | the shell command Aulthium runs, from inside your plugin's own folder   |
| `runtime`     | no       | a command Aulthium checks exists before running `entry` (e.g. `python3`, `node`); skip this if `entry` needs nothing special |
| `version`     | no       | free-form string, informational only                                    |

`entry` can be anything runnable from a shell: `python3 webchat.py`,
`node server.js`, `./run.sh`, a compiled binary, etc. Aulthium runs it with
`eval`, `cd`'d into your plugin's folder, so relative paths inside your
entry command work as expected.

## Installing it

```
t> plugin install /path/to/your-plugin-folder
```

This copies the folder into `~/.aulthium/plugins/<name>/` (name comes
from the manifest, not the source folder's name). Then:

```
t> plugin list          # see it
t> plugin info <name>   # see the full manifest
t> plugin run <name>    # launch it (asks for y/N confirmation first)
```

Anything after the name on `t> plugin run <name> ...` is passed straight
through as extra arguments to your `entry` command.

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

A minimal plugin needs nothing more than a manifest and one file:

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
  trust.
- `t> plugin run` always asks for a y/N confirmation before launching,
  regardless of `t> confirm off` (that toggle only covers the in-chat
  file/shell/MCP agent actions, not plugins).
- There's currently no uninstall command — remove a plugin by deleting
  its folder under `~/.aulthium/plugins/`.
