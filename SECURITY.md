# Security Policy

Umbra is a code editor with a coding agent that can read your project, edit files, and run
commands. Penumbra is the text engine and the intelligence libraries under it. Both handle
untrusted input (project files, model output, language servers), so security reports are
welcome and taken seriously.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion for an unfixed vulnerability, a
credential, or exploitable details.**

Report it privately through GitHub:

1. Open [Security → Report a vulnerability](https://github.com/alex-cova/Penumbra/security/advisories/new).
2. Describe the problem using the checklist below.

If the form is unavailable, open a public issue that says only that you have a security
report (no details), and the maintainer will arrange a private channel.

### What to include

- The affected Umbra version or commit, and your macOS version
- The component: Umbra's agent, a project system, the terminal, the updater, or a library
  (`Penumbra`, `EditorIntelligence`, `JavaIntelligence`, …)
- Steps to reproduce, a minimal project or proof of concept, and logs with credentials and
  personal data removed
- The impact you see and what an attacker needs (for example "a malicious repository the
  user opens", or "a hostile model response")
- A suggested fix, if you have one

## What happens next

- You will get an acknowledgement within **7 days**. If you hear nothing after that, follow
  up on the same report.
- Valid reports follow **coordinated disclosure with a 90-day window**, which we can shorten
  or extend with you depending on severity and the fix. Please don't publish details before
  a fix is released or the window ends.
- Fixes ship in a new release (Umbra updates through Sparkle) and are described in the
  release notes and a GitHub security advisory. Reporters are credited unless they ask not
  to be.

## Supported versions

Only the latest release of Umbra and the `main` branch of the libraries receive security
fixes. Please reproduce on the latest release before reporting.

## What is in scope

Reports about any of these are welcome:

- **The agent.** Bypassing a permission mode, an approval prompt, or a permission rule
  (`.umbra/settings.json`, `AGENTS.md`); running a command or editing a file outside the
  project without consent; prompt injection from project files, web content or tool output
  that leads to an action the user didn't approve.
- **Project trust.** Starting a build or process (Gradle, Maven, npm) before the
  user has granted trust to the folder.
- **Secrets and data.** API keys leaving the Keychain, secrets written to logs or session
  files, or data sent to a model provider without the user's consent.
- **Sandbox and hardened runtime.** Anything that needs an entitlement the app shouldn't
  have, or a library target that spawns a process or makes a network call on its own.
- **Updates and bundling.** Problems in the Sparkle update path or in the build and release
  scripts that could ship a tampered app.
- **Memory safety and parsing.** Crashes or code execution from a crafted file in the
  engine, the tree-sitter grammars, the hex editor, or the Java, Swift and TypeScript
  indexers.

Out of scope: vulnerabilities in a model provider or in a third-party language server
itself, behavior the user explicitly approved (for example running a command they accepted),
and issues that need a machine the attacker already controls. Ordinary bugs and feature
requests belong in public issues.

## For contributors

- Never commit credentials, tokens, private keys, or real user data, including in test
  fixtures. Tests that call paid APIs are opt-in by environment variable, and CI must not
  be handed a key.
- If you commit a secret by mistake, report it privately and revoke it at once. Deleting
  the file does not remove it from Git history.
- Keep `Penumbra` App Store–safe: public APIs only, no `Process` in library targets, no
  hidden network calls. See [CONTRIBUTING.md](CONTRIBUTING.md#rules-that-protect-the-libraries).
