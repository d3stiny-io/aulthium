<p align="center">
  <img src="assets/src/public/icon.png" width="90" alt="Aulthium">
</p>

<h1 align="center">Contributing to Aulthium</h1>

<p align="center">
  <em>Whether you're fixing a bug, building a plugin, writing docs, or just have an idea — your contribution is welcome, and it'll be running on someone's phone by next week.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=for-the-badge" alt="PRs Welcome">
  <img src="https://img.shields.io/badge/good%20first%20issue-friendly-blue?style=for-the-badge" alt="Beginner friendly">
</p>

---

### Contents

- [Ways to Contribute](#-ways-to-contribute)
- [Plugins](#-plugins)
- [Skills](#-skills)
- [Reporting Bugs](#-reporting-bugs)
- [Feature Requests](#-feature-requests)
- [MCP Contributions](#-mcp-contributions)
- [Android & Termux](#-android--termux)
- [Development Workflow](#%EF%B8%8F-development-workflow)
- [Pull Request Guidelines](#-pull-request-guidelines)
- [Code Quality](#-code-quality)
- [Documentation Contributions](#-documentation-contributions)
- [Community Contributions](#-community-contributions)
- [Security](#-security)

---

Thank you for your interest in contributing to **Aulthium**! 🎉

Aulthium is the open-source AI agent built for the terminal you actually use — including the one in your pocket, via Android/Termux. It's designed to be extensible through **plugins, skills, MCP, and integrations**, so there are dozens of ways to improve it without ever touching the core.

## 🚀 Ways to Contribute

| | | |
| :--- | :--- | :--- |
| 🐛 Report bugs | 💡 Suggest features | 🧑‍💻 Improve the core |
| 🧩 Create plugins | 🧠 Create skills | 🔗 Improve MCP integrations |
| 🌐 Improve web capabilities | 📱 Improve Android/Termux support | 📚 Improve documentation |
| 🧪 Test releases | 🎨 Improve UI and design | 🔍 Review pull requests |

> **You don't need to modify the core repository to make a useful contribution.**

## 🧩 Plugins

Plugins are an important part of the Aulthium ecosystem. If your idea doesn't need to be part of the core agent, consider making it a plugin.

Examples include:

- Developer tools
- API integrations
- Web tools
- Automation
- File utilities
- Custom interfaces
- AI provider integrations
- Experimental agent capabilities

> Before adding a new core feature, ask: **could this be a plugin instead?** See the [Plugin Development Guide](docs/guides/plugin/BUILD_PLUGIN.md).

⚠️ Plugins are trusted programs and may run with the permissions of the user running Aulthium. Only install plugins you trust.

## 🧠 Skills

Skills provide reusable instructions and workflows that specialize how Aulthium handles tasks. Good skills should:

- Have a clear purpose
- Be reusable
- Be easy to understand
- Avoid unnecessary instructions
- Work consistently with Aulthium's agent behavior

If a workflow could be useful to other Aulthium users, consider contributing it as a skill.

## 🐛 Reporting Bugs

Before opening a bug report:

1. Check existing issues.
2. Make sure you're using a supported/current version.
3. Try to reproduce the issue.
4. Remove sensitive information from logs.

Include:

- Aulthium version
- Device and OS
- Termux version, when relevant
- Steps to reproduce
- Expected vs. actual behavior
- Relevant error messages or logs

### 🔐 Never Include Secrets

| Never include |
| :--- |
| API keys |
| OAuth tokens |
| Passwords |
| Access tokens |
| Private credentials |
| Other sensitive information |

## 💡 Feature Requests

Before requesting a feature, check whether it could be implemented as a **plugin or skill**.

A good feature request explains:

- What problem it solves
- Why it would be useful
- Who would benefit
- How you expect it to work
- Whether it could be implemented as a plugin or skill

## 🔗 MCP Contributions

Aulthium supports MCP-based integrations. When contributing MCP functionality:

- Prefer standards-compliant implementations.
- Keep provider-specific logic separate from generic MCP functionality.
- Never hard-code credentials or commit API keys/tokens.
- Test authentication and connection failures.
- Document required permissions and configuration.

For OAuth-based MCP integrations, follow the relevant MCP and provider documentation instead of creating unnecessary custom authentication flows.

## 📱 Android & Termux

Android and Termux are important parts of Aulthium. When changing functionality that affects mobile users:

- Test on Termux when possible.
- Avoid unnecessary desktop-only assumptions.
- Consider limited storage, memory, and connectivity.
- Keep installation and configuration simple.
- Document Android-specific requirements when necessary.

## 🛠️ Development Workflow

**1. Fork the repository** on GitHub.

**2. Clone your fork:**

```bash
git clone https://github.com/d3stiny-io/aulthium.git
cd aulthium
```

**3. Create a branch** with a descriptive name:

```
feature/plugin-improvement
fix/mcp-connection
docs/update-plugin-guide
```

**4. Make your changes** — keep them focused and avoid unrelated modifications.

**5. Test your changes** before submitting. For changes involving:

- **MCP** → test connections and failure handling.
- **Plugins** → test installation and execution.
- **Skills** → test the workflow.
- **Android/Termux** → test in Termux when possible.

**6. Commit your changes** with a concise message:

```
Add MCP connection handling
Improve plugin validation
Fix Termux startup issue
Update plugin documentation
```

**7. Open a pull request** describing:

- What you changed
- Why you changed it
- How you tested it
- Any limitations or known issues

## 🔍 Pull Request Guidelines

A good pull request should:

- Solve a clear problem
- Keep changes focused
- Include appropriate tests
- Update documentation when necessary
- Avoid unnecessary dependencies
- Avoid unrelated formatting changes
- Never contain secrets

Maintainers may request changes before merging. Code review is intended to improve the project, not criticize contributors.

## 🧹 Code Quality

| Prefer | Avoid |
| :--- | :--- |
| Readable code | Unnecessary rewrites |
| Small, focused changes | Duplicating existing functionality |
| Existing project patterns | Hard-coded credentials |
| Clear error handling | Debug code |
| Useful documentation | Unused dependencies |
| Tests for important behavior | Breaking functionality without a clear reason |

## 📚 Documentation Contributions

Documentation is a real contribution. You can improve:

- README.md
- Installation guides
- Plugin / skill / MCP documentation
- Troubleshooting guides
- Examples, comments, and explanations

If something confused you while using Aulthium, improving the documentation around it can help the next person.

## 🌍 Community Contributions

You can also help Aulthium by:

- Sharing your plugins and useful skills
- Testing development builds
- Helping other users
- Reviewing issues and improving examples
- Demonstrating Aulthium workflows

A growing ecosystem is built by more than just commits to the core repository.

## 🔒 Security

If you discover a security vulnerability, **do not publicly disclose sensitive details in a normal issue**. See [SECURITY.md](SECURITY.md) for the security reporting process.

---

<p align="center">
  <strong>Every contribution helps Aulthium become more capable, reliable, and accessible.</strong><br>
  Whether you submit one line of documentation or build an entire plugin, thank you for helping build Aulthium. 🚀
</p>
