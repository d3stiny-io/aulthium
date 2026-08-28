<p align="center">
  <img src="assets/src/public/icon.png" alt="Aulthium Logo" width="240">
</p>

<h1 align="center">Aulthium</h1>

<p align="center">
  <strong>Your open-source AI agent for the terminal.</strong>
</p>

<p align="center">
  Code, automate, search, and extend your workflow with plugins.
</p>

<p align="center">
  <a href="https://github.com/d3stiny-io/aulthium/stargazers">
    <img src="https://img.shields.io/github/stars/d3stiny-io/aulthium?style=flat-square" alt="Stars">
  </a>
  <a href="https://github.com/d3stiny-io/aulthium/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/d3stiny-io/aulthium?style=flat-square" alt="License">
  </a>
</p>

---

## ⚡ What is Aulthium?

**Aulthium** is a free and open-source AI agent designed for terminal environments.

It can work with your files, execute shell commands, search the web, connect to MCP servers, and extend its capabilities through plugins.

Aulthium is designed to be useful on both traditional computers and mobile devices running **Termux**.

> 🛡️ AI proposes. You stay in control.

---

## ✨ Features

- 🤖 **AI Agent** — Work with your projects using natural language.
- 📝 **File Operations** — Read, create, modify, and inspect files.
- ⚡ **Shell Execution** — Execute commands with your approval.
- 🔍 **Web Search** — Search for current information and documentation.
- 🔗 **HTTPS MCP** — Connect to compatible MCP servers.
- 🧩 **Plugin System** — Extend Aulthium with your own plugins.
- 🌐 **WebChat** — Use Aulthium through a local browser interface.
- 🔌 **BYOK** — Bring your own AI provider and API key.
- 📱 **Termux Support** — Run Aulthium directly on Android.
- 🆓 **Open Source** — Licensed under GPL-3.0.

---

## 🚀 Quick Start

Run Aulthium with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/d3stiny-io/aulthium/main/aulthium.sh)
```

Configure your AI provider and start using the agent.

---

## 🧩 Plugins

One of Aulthium's biggest features is its **extensible plugin system**.

Plugins allow you to add new functionality without modifying the Aulthium core.

A plugin is stored inside:

```text
~/.aulthium/plugins/<plugin-name>/
├── plugin.json
└── ...
```

A plugin manifest can define information such as its name, description, version, runtime, and entry point.

Example:

```json
{
  "name": "hello",
  "description": "A simple Aulthium plugin",
  "version": "1.0.0",
  "entry": "python3 hello.py",
  "runtime": "python3"
}
```

### Plugin Commands

Plugins can be managed from inside Aulthium:

```text
t> plugin list
t> plugin info <name>
t> plugin install /path/to/plugin
t> plugin run <name>
```

### 🛠️ Create Your Own Plugin

Anyone can build plugins for Aulthium.

This makes it possible to create:

- Custom tools
- Automation plugins
- Web interfaces
- Developer utilities
- API integrations
- Personal workflows
- Experimental features

Read the plugin development guide:

[Build Your Own Plugin](docs/guides/plugin/BUILD_PLUGIN.md)

> ⚠️ **Security:** Plugins are trusted programs. They may run with your normal user permissions, so only install plugins you trust.

---

## 🌐 WebChat

Aulthium includes a built-in **WebChat plugin**.

WebChat provides a local browser-based interface for interacting with your Aulthium agent.

Run it using:

```text
t> plugin run webchat
```

The WebChat plugin is designed to:

- 🌐 Provide a browser-based chat interface
- 🔌 Use your configured AI provider
- 🧠 Use your configured model
- 📱 Work well on mobile devices
- 🔒 Run locally

---

## 🔍 Web Search

Aulthium can search the web when the agent needs current information.

This can be useful for:

- Documentation
- API references
- Package information
- Debugging
- Recent changes
- Unfamiliar errors

Instead of relying only on the model's existing knowledge, Aulthium can retrieve information from the web and provide it to the agent.

---

## 🔗 MCP Support

Aulthium supports **Model Context Protocol (MCP) over HTTPS**.

MCP allows Aulthium to connect to external tool servers and use the capabilities they provide.

This can be used to extend the agent beyond its built-in functionality.

> 🧪 MCP support is still evolving.

---

## 🔌 Bring Your Own Provider

Aulthium is designed around **Bring Your Own Key (BYOK)**.

You can configure your own supported AI provider and model.

Depending on the current version, this may include:

- OpenRouter
- Google
- Mistral
- Hugging Face
- NVIDIA NIM
- OpenAI-compatible APIs
- Custom endpoints

You provide the API key.

You choose the provider.

You choose the model.

---

## 🛡️ Human-in-the-Loop

Aulthium doesn't blindly execute everything the AI requests.

Actions such as shell commands can require user approval.

Example:

```text
┌─ ❯ SHELL RUN ───────────────────────────────
│ cwd: /your/project
│ npm install example-package
└──────────────────────────────────────────────
⚠ This is NOT sandboxed to the workspace folder.
? Run this command? [y/N]
```

**The AI suggests. You decide.**

Always review commands, file modifications, MCP connections, and plugins before approving them.

---

## 📱 Built for Mobile

Aulthium can run directly inside **Termux on Android**.

This makes it possible to have an AI development agent without needing a traditional desktop computer.

It can also run on:

- 🐧 Linux
- 🍎 macOS
- 📱 Android with Termux

---

## 🧠 AI-Assisted Development

Aulthium is a **vibe-coded open-source project**.

LLMs are heavily involved in the implementation, while the project's direction, experimentation, design decisions, testing, and improvements remain human-driven.

The project is continuously evolving, so bugs and experimental features are expected.

If you find something that can be improved:

- Open an issue
- Submit a pull request
- Build a plugin
- Improve the documentation
- Share your ideas

---

## 📋 Requirements

### Core

- Bash
- curl
- Internet connection
- API key for your selected AI provider

### Plugins

Plugins may have additional requirements depending on their implementation.

For example, a plugin may require:

- Python
- Node.js
- Another runtime
- Additional packages

---

## 🤝 Contributing

Contributions are welcome!

You can contribute by:

- 🐛 Reporting bugs
- 💡 Suggesting features
- 🔧 Fixing issues
- 📚 Improving documentation
- 🧩 Creating plugins
- 🔀 Opening pull requests

Not every feature needs to become part of the Aulthium core.

If you want to experiment with something new, **consider building a plugin.**

---

## 📄 License

Aulthium is licensed under the **GPL-3.0 License**.

See [LICENSE](LICENSE) for the full license.

---

<p align="center">
  <strong>Built with vision. Powered by AI. Improved by humans.</strong>
</p>

<p align="center">
  ⭐ If Aulthium is useful to you, consider giving it a star.
</p>
