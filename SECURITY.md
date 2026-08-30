# Security Policy
 
Security is important to Aulthium.
 
Aulthium is an AI coding agent that can interact with files, terminals, plugins, MCP servers, external services, and user-configured AI providers. Because of this, security issues can potentially affect both Aulthium and the environments where it runs.
 
## Supported Versions
 
Security fixes are primarily provided for the latest supported version of Aulthium.
 
  
 
Version
 
Supported
 
   
 
Latest release
 
✅
 
 
 
Older releases
 
⚠️ Best effort
 
 
 
Unmaintained releases
 
❌
 
  
 
If possible, update to the latest version before reporting an issue.
 
## Reporting a Vulnerability
 
**Please do not publicly disclose security vulnerabilities through GitHub Issues.**
 
If you believe you have found a security vulnerability, report it privately through GitHub's available private security reporting mechanisms.
 
A useful report should include:
 
 
- Affected Aulthium version or commit
 
- Affected component
 
- Description of the vulnerability
 
- Steps to reproduce
 
- Expected behavior
 
- Actual behavior
 
- Potential security impact
 
- Suggested mitigation, if known
 

 
Please provide enough information for the issue to be reproduced and investigated.
 
### 🔐 Never Include Secrets
 
Do not include any of the following in a security report:
 
 
- API keys
 
- OAuth access tokens
 
- OAuth refresh tokens
 
- Passwords
 
- Private keys
 
- Personal access tokens
 
- Session tokens
 
- Private repository data
 
- Other credentials
 

 
Redact sensitive information before submitting a report.
 
## 🧩 Plugin Security
 
Aulthium plugins should be treated as **trusted code**.
 
Depending on their implementation, plugins may be able to access capabilities available to the Aulthium process, including files, network resources, commands, or other configured functionality.
 
Only install plugins from sources you trust.
 
Before installing a third-party plugin:
 
 
1. Review its source code when available.
 
2. Check what permissions or capabilities it uses.
 
3. Review its dependencies.
 
4. Check where it sends data.
 
5. Avoid plugins that request unnecessary access.
 

 
Aulthium does not guarantee the security of third-party plugins.
 
## 🔗 MCP Security
 
MCP servers should also be treated as external and potentially untrusted services.
 
MCP tools may have significant capabilities depending on the server.
 
Users should:
 
 
- Connect only to trusted MCP servers.
 
- Review requested permissions.
 
- Use the minimum permissions necessary.
 
- Keep authentication credentials private.
 
- Review potentially destructive operations.
 
- Keep MCP clients and servers updated.
 

 
MCP tool descriptions and tool results should not automatically be considered trustworthy instructions.
 
Aulthium should treat external MCP content as untrusted data.
 
## 🤖 AI-Generated Code
 
AI-generated code may contain:
 
 
- Bugs
 
- Vulnerabilities
 
- Incorrect assumptions
 
- Unsafe commands
 
- Malicious or compromised dependencies
 
- Unexpected behavior
 

 
Always review generated code and commands before using them in environments where mistakes could cause damage.
 
Aulthium does not guarantee that AI-generated output is secure or correct.
 
## 💻 Terminal and File Access
 
Aulthium may operate on the user's local environment.
 
Users should understand what commands and file operations the agent is being asked to perform.
 
For potentially destructive or irreversible operations, appropriate user confirmation should be used whenever supported.
 
Do not run Aulthium with unnecessarily elevated privileges.
 
Avoid giving the agent access to sensitive directories unless required.
 
## 🔑 API Keys and Credentials
 
Aulthium may work with user-provided AI provider credentials and external service credentials.
 
Credentials should:
 
 
- Never be committed to Git.
 
- Never be included in bug reports.
 
- Never be shared publicly.
 
- Never be placed in source code.
 
- Be stored using appropriate secure mechanisms.
 
- Be rotated if accidentally exposed.
 

 
If a credential is accidentally committed or exposed, revoke or rotate it immediately.
 
## 📱 Android and Termux
 
When running Aulthium through Termux or other Android environments, users should consider the permissions available to the Termux environment and installed applications.
 
Keep:
 
 
- Android
 
- Termux
 
- Aulthium
 
- Plugins
 
- Dependencies
 

 
reasonably up to date.
 
Do not grant unnecessary Android or Termux permissions.
 
## 🌐 Network Security
 
Aulthium may communicate with external services, including AI providers and MCP servers.
 
Users should prefer secure HTTPS connections.
 
Aulthium should not disable TLS certificate verification merely to make an external service work.
 
## 🛡️ Dependency Security
 
Aulthium depends on third-party software and libraries.
 
Security issues may originate from dependencies as well as Aulthium's own code.
 
Contributors should:
 
 
- Avoid unnecessary dependencies.
 
- Keep dependencies reasonably up to date.
 
- Review security advisories.
 
- Avoid untrusted packages.
 
- Pin or constrain dependencies where appropriate.
 

 
## 🚨 Responsible Disclosure
 
When reporting a vulnerability, please allow maintainers reasonable time to investigate and address the issue before publicly disclosing technical details.
 
The goal is to protect Aulthium users while allowing vulnerabilities to be fixed responsibly.
 
## ❤️ Security Is a Community Effort
 
Security isn't only the responsibility of maintainers.
 
If you discover a vulnerability, report it responsibly.
 
If you build a plugin or MCP integration, design it with security in mind.
 
If you use Aulthium, keep your credentials private and review what the agent and its extensions are allowed to do.
 
**Thank you for helping keep Aulthium secure.**