# ipython-plugin

Routes the AI's Python `SHELL_RUN` commands through one persistent
IPython kernel per terminal session, instead of a fresh interpreter every
time.

## What it does

Normally, every `SHELL_RUN` the AI proposes spawns a brand-new process —
so variables, imports, and state from one Python command don't survive
to the next. This plugin fixes that for anything that looks like a
Python invocation, by keeping one real IPython kernel alive per terminal
session and routing that code through it instead:

- **State survives between calls** — variables and imports set in one
  `SHELL_RUN` are still there in the next, the way a real interactive
  session works.
- **Better errors** — failures come back with IPython's verbose,
  per-frame-locals tracebacks instead of a bare Python traceback.
- **Magics work** — `%%writefile`, `%history`, `%who`, `%time`, and `!`
  shell-escapes all function normally inside the kernel.

## How it's wired in

This plugin has three files working together:

- **`ipy_run.py`** — the `shell_exec` hook entry point. Called on
  *every* `SHELL_RUN` the AI proposes, **before** the user confirms it.
  It has no side effects: it only decides whether the command looks like
  a Python invocation, and if so prints a rewritten command line that
  will hand that code to the kernel once the user approves and Aulthium
  actually runs it. Anything not recognizably Python passes through
  untouched. It's also the entry point for the `ipy>` prefix shorthand,
  used when the *user* (not the AI) types code directly — that case runs
  for real immediately, with no confirmation step, since the user typing
  it at the prefix already is the approval.
- **`ipy_server.py`** — the persistent kernel daemon. Spawned lazily by
  the client on the first Python `SHELL_RUN` of a session, and reused for
  every one after that. Talks JSON over a Unix domain socket: `{"code":
  ..., "cwd": ...}` in, `{"stdout": ..., "stderr": ..., "success": bool}`
  out. Single-threaded by design — the AI's actions are already
  sequential, so there's nothing to gain from concurrency, and it would
  only complicate kernel state.
- **`ipy_client.py`** — the thin client the rewritten command actually
  invokes once approved. Ensures the session's kernel daemon is running
  (spawning it if needed), sends the code over the socket, and prints
  back exactly what the kernel produced. Exits 0 if the code ran without
  raising, 1 otherwise, so a normal `SHELL_RUN` exit code still means
  what the AI expects.

The kernel's lifetime is scoped to the terminal session via `os.getsid(0)`
— stable across every subshell/subprocess Aulthium forks within one
`SHELL_RUN`, but different between separate sessions/terminals, so each
terminal gets its own kernel and they don't leak into each other.

## Requirements

```bash
pip install ipython --break-system-packages
```

If IPython isn't installed, the server exits with a clear error and
Python commands simply run the normal, non-persistent way.

## Usage

Once enabled, this is transparent — no action needed for AI-proposed
Python `SHELL_RUN` commands, which are automatically routed through the
persistent kernel after you confirm them.

To run code directly yourself:

```
ipy> import pandas as pd; df = pd.read_csv("data.csv")
ipy> df.head()
```

## Configuration

Set with `t> plugin config ipython-plugin set <key> <value>`:

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `idle_timeout_minutes` | `120` | How long an idle kernel stays alive before shutting down |

## Permissions

Declares `filesystem` and `shell` in `plugin.json` — it spawns a local
kernel process, communicates over a Unix socket file, and executes code
with the user's shell privileges (only after the normal confirmation
step, same as any other `SHELL_RUN`).
