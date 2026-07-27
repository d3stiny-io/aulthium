<p align="center">
  <img
    src="https://raw.githubusercontent.com/d3stiny-io/termix-agent/main/assets/src/public/icon.png"
    alt="Termix Agent"
    width="120"
  >
</p><h1 align="center">Termix Agent</h1><p align="center">
  <strong>Your AI coding agent, right inside your terminal.</strong>
</p><p align="center">
  Write code. Fix bugs. Read files. Run commands. Search the web.<br>
  <strong>You stay in control.</strong>
</p><p align="center">
  <a href="https://github.com/d3stiny-io/termix-agent/stargazers"><img src="https://img.shields.io/github/stars/d3stiny-io/termix-agent?style=flat-square&color=yellow" alt="Stars"></a>
  <a href="https://github.com/d3stiny-io/termix-agent/blob/main/LICENSE"><img src="https://img.shields.io/github/license/d3stiny-io/termix-agent?style=flat-square&color=blue" alt="License"></a>
  <a href="https://github.com/d3stiny-io/termix-agent/releases"><img src="https://img.shields.io/github/v/release/d3stiny-io/termix-agent?style=flat-square&color=green" alt="Release"></a>
</p><p align="center">
  <a href="#-quick-start">Get Started</a> •
  <a href="#-features">Features</a> •
  <a href="#-web-search">Web Search</a> •
  <a href="#-contributing">Contributing</a>
</p>

---

⚡ Code at the speed of thought.

You already have a terminal.

Now give it an AI.

Termix Agent is a free, open-source AI coding assistant built to work directly from your terminal. Describe what you want in natural language and let the agent help you understand, create, edit, debug, and work with your code.

It can also search the web for fresh information and use those search results when reasoning about your request.

No giant IDE.

No mandatory subscription.

No locked-in AI provider.

Just your terminal, your API key, and an AI coding agent.

«🛡️ AI proposes. You stay in control.»

---

🚀 Quick Start

Start Termix Agent with one command:

bash <(curl -fsSL https://raw.githubusercontent.com/d3stiny-io/termix-agent/main/termix-agent.sh)

The script starts Termix Agent directly.

There is no separate installation step or launcher command required for this startup method.

🔌 Choose Your Provider

When Termix Agent starts, it gives you the available AI provider choices supported by the current version.

Choose the provider you want to use, provide the required configuration, and continue.

The basic flow is:

Run termix-agent.sh
        │
        ▼
Termix Agent starts
        │
        ▼
Choose AI provider
        │
        ▼
Configure provider
        │
        ▼
Agent starts
        │
        ▼
Chat with your coding agent

One command → choose your provider → start coding.

---

💬 Talk to Your Code

You don't need to memorize commands for every task.

Just tell Termix Agent what you want.

💻 Build

Create a REST API using Express with
authentication and a SQLite database.

🐛 Debug

Find the TypeScript errors in this
project and fix them.

✏️ Refactor

Refactor this function to use async/await
instead of callbacks.

📚 Understand

Explain what this regex does and
suggest a safer alternative.

🔍 Search

Search the web for the latest
documentation about this error.

Termix Agent can use the information it finds on the web as additional context while working on your request.

---

✨ Features

| Feature| Description
🤖| Natural Language Coding| Describe what you want and let the AI work through the task.
📝| Read & Edit Files| Read, create, modify, and refactor files in your project.
🗂️| Project Awareness| Work with the files and structure of your current workspace.
⚡| Shell Commands| Execute commands and scripts when needed, with your approval.
🔧| Debug & Fix| Analyze errors, logs, and failed commands to help find solutions.
🔍| Real-Time Web Search| Search the web for current technical information and documentation.
🧠| Web-Aware Reasoning| Use web-search results as context while reasoning about your task.
🔌| Bring Your Own Provider| Choose your supported AI provider and use your own API key.
📜| Bash-Based| The core agent is distributed as a portable Bash script.
🛡️| Human-in-the-Loop| Actions requiring execution are presented for your approval.
🔒| Zero Telemetry| No built-in proprietary tracking or analytics.
🆓| Free & Open Source| Open source and licensed under GPL-3.0.

---

🔍 Real-Time Web Search

Sometimes an AI's built-in knowledge isn't enough.

Documentation changes.

APIs change.

Packages change.

Frameworks change.

Errors change.

Termix Agent can search the web when it needs fresh information.

You can ask it things like:

Search the web for the latest documentation
for this framework.

or:

Search the web for a solution to this error.

The search results can then be read and used as context by the AI.

Useful for:

- 📚 Current documentation
- 🔧 Debugging
- 📦 Package information
- 🌐 API references
- 🆕 Recent changes
- 🧩 Unfamiliar errors
- 💡 Finding possible solutions

---

🛡️ You Stay in Control

Termix Agent is designed around human-in-the-loop execution.

The AI can figure out what it thinks should happen, but actions that affect your environment are not something you should blindly trust.

When Termix needs to execute a command, you can review it before allowing it to run.

For example:

Termix wants to run:

npm install express

Continue? [y/N]

You decide whether to continue.

«The AI can suggest the action. You approve it.»

Always review commands and file changes before approving them, especially when working with important projects or sensitive files.

---

🔌 Bring Your Own AI Provider

Termix Agent is built around the idea that you should choose how your AI is powered.

Depending on the current version, you can choose from supported providers such as:

- OpenRouter
- OpenAI
- OpenAI-compatible providers

Your API key belongs to you.

Your provider is your choice.

Your model selection is yours.

Termix Agent doesn't require you to use one proprietary AI platform.

---

📱 Terminal First

Termix Agent is made for environments where a terminal is already available.

Supported environments include:

- 🐧 Linux
- 🍎 macOS
- 📱 Termux on Android

That makes it possible to use an AI coding assistant even when you're working from a mobile terminal.

---

📜 Lightweight by Design

The core project is centered around:

termix-agent.sh

The goal is to keep Termix Agent straightforward and portable rather than turning it into a large desktop application.

You can start it directly with:

bash <(curl -fsSL https://raw.githubusercontent.com/d3stiny-io/termix-agent/main/termix-agent.sh)

Minimal setup.

Terminal-first.

Open source.

---

🆚 Why Termix Agent?

| Termix Agent| Traditional / Commercial Tools
💰 Cost| Free software + your provider's API costs| May require subscriptions
🔌 AI Provider| Bring your own| Often tied to a platform
🖥️ Interface| Terminal| Often desktop / IDE focused
📦 Startup| One command| Can require more setup
🌐 Web Search| Built into the agent| Depends on the tool
🔓 Source| Open source| Often proprietary
🛡️ Control| User approval for actions| Depends on the tool
📱 Termux| Supported| Often unavailable
📊 Telemetry| Zero built-in telemetry| Varies by product

---

🧠 The Vibe-Code Story

«Built with vision. Powered by AI. Improved by humans.»

Full disclosure: Termix Agent is a vibe-coded project.

The creator does not manually write every line of raw syntax. The project is driven by product vision, experimentation, constraints, user experience, and safety requirements, while LLMs generate much of the implementation.

That makes Termix Agent an experiment in AI-assisted software development itself.

And because of that, the code may not always be perfect.

You might find:

- Unoptimized logic
- Strange edge cases
- Code that could be cleaner
- Bugs that need fixing

That's part of the experiment.

If you find something that could be better:

Don't just complain about it. Improve it.

Open an issue.

Submit a pull request.

Help make Termix Agent better.

---

🤝 Contributing

Termix Agent is open source and contributions are welcome.

Found a bug?

👉 "Open an issue" (https://github.com/d3stiny-io/termix-agent/issues)

Have an improvement?

👉 "Submit a pull request" (https://github.com/d3stiny-io/termix-agent/pulls)

Have an idea?

Let's build it.

---

📋 Requirements

- OS: Linux, macOS, or Termux (Android)
- Shell: Bash
- Network: Internet connection
- Dependency: "curl"
- API Key: Required for the AI provider you select

---

📄 License

Termix Agent is licensed under the GPL-3.0 License.

See the "LICENSE" (https://github.com/d3stiny-io/termix-agent/blob/main/LICENSE) file for the complete license text.

---

<p align="center">
  <strong>Termix Agent</strong>
</p><p align="center">
  AI coding. In your terminal. On your terms.
</p><p align="center">
  ⭐ If Termix Agent is useful to you, consider giving it a star.
</p>
