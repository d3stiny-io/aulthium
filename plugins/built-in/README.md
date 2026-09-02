# Built-in plugins

Plugins that ship with Aulthium out of the box. Each is a normal
Aulthium plugin — nothing here uses a private API unavailable to plugins
you write yourself. See the [Plugin Development Guide](../../docs/guides/plugin/BUILD_PLUGIN.md)
for the full plugin contract, and each plugin's own README for details.

| Plugin | Mode | What it does |
| :--- | :--- | :--- |
| [`webchat`](webchat/) | foreground | Chat with the AI from a browser tab instead of the terminal |
| [`betterwebsearch`](betterwebsearch/) | hook (`web_search`) | Upgrades `WEB_SEARCH` with real fetched article text instead of search-engine snippets |
| [`skills`](skills/) | hook (`chat_pre`) | Local library of Claude-style `SKILL.md` files, auto-injected when relevant |
| [`ipython-plugin`](ipython-plugin/) | hook (`shell_exec`) | Runs the AI's Python commands through one persistent IPython kernel per session |

## Enabling / configuring

Most built-in hook plugins (`betterwebsearch`, `skills`, `ipython-plugin`)
`autostart` and run transparently once enabled. `webchat` is launched
on demand:

```
t> plugin run webchat
```

All of them accept configuration via:

```
t> plugin config <name> set <key> <value>
```

See each plugin's own `plugin.json` for its defaults, and its README for
what each key controls.

## Permissions

Plugins are trusted programs and may run with the permissions of the
user running Aulthium — the `permissions` field in each `plugin.json` is
a declaration of intent, not an enforced sandbox. Only install or enable
plugins you trust; see [CONTRIBUTING.md](../../CONTRIBUTING.md) for more.
