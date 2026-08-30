# Contributing to Aulthium
 
Thank you for your interest in contributing to **Aulthium**! 🎉
 
Aulthium is an open-source AI coding agent built with Android and Termux in mind. It is designed to be extensible through **plugins, skills, MCP, and integrations**, giving contributors many ways to improve the project without modifying the core.
 
Whether you're fixing a bug, creating a plugin, improving documentation, or suggesting an idea, your contribution is welcome.
 
## 🚀 Ways to Contribute
 
 
- 🐛 Report bugs
 
- 💡 Suggest features
 
- 🧑‍💻 Improve the core
 
- 🧩 Create plugins
 
- 🧠 Create skills
 
- 🔗 Improve MCP integrations
 
- 🌐 Improve web capabilities
 
- 📱 Improve Android/Termux support
 
- 📚 Improve documentation
 
- 🧪 Test releases
 
- 🎨 Improve UI and design
 
- 🔍 Review pull requests
 

 
**You don't need to modify the core repository to make a useful contribution.**
 
## 🧩 Plugins
 
Plugins are an important part of the Aulthium ecosystem.
 
If your idea doesn't need to be part of the core agent, consider making it a plugin.
 
Examples include:
 
 
- Developer tools
 
- API integrations
 
- Web tools
 
- Automation
 
- File utilities
 
- Custom interfaces
 
- AI provider integrations
 
- Experimental agent capabilities
 

 
Before adding a new core feature, ask:
 
 
**Could this be a plugin instead?**
 
 
See the Plugin Development Guide.
 
 
⚠️ Plugins are trusted programs and may run with the permissions of the user running Aulthium. Only install plugins you trust.
 
 
## 🧠 Skills
 
Skills provide reusable instructions and workflows that specialize how Aulthium handles tasks.
 
Good skills should:
 
 
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
 
- Termux version when relevant
 
- Steps to reproduce
 
- Expected behavior
 
- Actual behavior
 
- Relevant error messages or logs
 

 
### 🔐 Never Include Secrets
 
Never include:
 
 
- API keys
 
- OAuth tokens
 
- Passwords
 
- Access tokens
 
- Private credentials
 
- Other sensitive information
 

 
## 💡 Feature Requests
 
Before requesting a feature, check whether it could be implemented as a **plugin or skill**.
 
A good feature request explains:
 
 
- What problem it solves
 
- Why it would be useful
 
- Who would benefit
 
- How you expect it to work
 
- Whether it could be implemented as a plugin or skill
 

 
## 🔗 MCP Contributions
 
Aulthium supports MCP-based integrations.
 
When contributing MCP functionality:
 
 
- Prefer standards-compliant implementations.
 
- Keep provider-specific logic separate from generic MCP functionality.
 
- Never hard-code credentials.
 
- Never commit API keys or tokens.
 
- Test authentication and connection failures.
 
- Document required permissions and configuration.
 

 
For OAuth-based MCP integrations, follow the relevant MCP and provider documentation instead of creating unnecessary custom authentication flows.
 
## 📱 Android & Termux
 
Android and Termux are important parts of Aulthium.
 
When changing functionality that affects mobile users:
 
 
- Test on Termux when possible.
 
- Avoid unnecessary desktop-only assumptions.
 
- Consider limited storage, memory, and connectivity.
 
- Keep installation and configuration simple.
 
- Document Android-specific requirements when necessary.
 

 
## 🛠️ Development Workflow
 
### 1. Fork the Repository
 
Create your own fork of Aulthium on GitHub.
 
### 2. Clone Your Fork
 `git clone https://github.com/d3stiny-io/aulthium.git cd aulthium ` 
### 3. Create a Branch
 
Use a descriptive branch name:
 `feature/plugin-improvement fix/mcp-connection docs/update-plugin-guide ` 
### 4. Make Your Changes
 
Keep changes focused and avoid unrelated modifications.
 
### 5. Test Your Changes
 
Run the project's existing tests and checks before submitting your contribution.
 
For changes involving:
 
 
- **MCP** → Test connections and failure handling.
 
- **Plugins** → Test installation and execution.
 
- **Skills** → Test the workflow.
 
- **Android/Termux** → Test in Termux when possible.
 

 
### 6. Commit Your Changes
 
Use a concise commit message.
 
Examples:
 `Add MCP connection handling Improve plugin validation Fix Termux startup issue Update plugin documentation ` 
### 7. Open a Pull Request
 
Describe:
 
 
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
 

 
Maintainers may request changes before merging.
 
Code review is intended to improve the project, not criticize contributors.
 
## 🧹 Code Quality
 
Prefer:
 
 
- Readable code
 
- Small, focused changes
 
- Existing project patterns
 
- Clear error handling
 
- Useful documentation
 
- Tests for important behavior
 

 
Avoid:
 
 
- Unnecessary rewrites
 
- Duplicating existing functionality
 
- Hard-coded credentials
 
- Debug code
 
- Unused dependencies
 
- Breaking existing functionality without a clear reason
 

 
## 📚 Documentation Contributions
 
Documentation is a real contribution.
 
You can improve:
 
 
- README.md
 
- Installation guides
 
- Plugin documentation
 
- Skill documentation
 
- MCP documentation
 
- Troubleshooting guides
 
- Examples
 
- Comments and explanations
 

 
If something confused you while using Aulthium, improving the documentation around it can help the next person.
 
## 🌍 Community Contributions
 
You can also help Aulthium by:
 
 
- Sharing your plugins
 
- Sharing useful skills
 
- Testing development builds
 
- Helping other users
 
- Reviewing issues
 
- Improving examples
 
- Demonstrating Aulthium workflows
 

 
A growing ecosystem is built by more than just commits to the core repository.
 
## 🔒 Security
 
If you discover a security vulnerability, **do not publicly disclose sensitive details in a normal issue**.
 
See SECURITY.md for the security reporting process.
 
## ❤️ Thank You
 
Every contribution helps Aulthium become more capable, reliable, and accessible.
 
Whether you submit one line of documentation or build an entire plugin, **thank you for helping build Aulthium.** 🚀