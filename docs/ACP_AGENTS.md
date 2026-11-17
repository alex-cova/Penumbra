# External ACP agents in Umbra

Umbra runs external coding agents over the [Agent Client Protocol](https://agentclientprotocol.com/)
(ACP v1, JSON-RPC 2.0, one JSON message per line over the agent's stdin/stdout). Every agent below uses
the same chat panel, permission cards, question and plan cards, checklist, Stop button and transcript
as Umbra's own agent. The runtime is AgentKit's `ACPClientSession`; see `docs/ACP_PLAN.md` for how it
was built. This page covers the agents Umbra knows by name.

## Supported agents

| Agent | Command | How Umbra gets it | Sign-in |
|---|---|---|---|
| Claude Code | `claude-agent-acp` | Adapter Umbra installs (Settings ▸ Agent ▸ Adapters) | Claude Code login or `ANTHROPIC_API_KEY` |
| Codex | `codex-acp` | Adapter Umbra installs | ChatGPT login or `CODEX_API_KEY` / `OPENAI_API_KEY` |
| Gemini CLI | `gemini --acp` | Detected | Gemini CLI login or `GEMINI_API_KEY` |
| OpenCode | `opencode acp` | Detected | opencode's providers |
| **Kiro** | `kiro-cli acp` | Detected | `kiro-cli login` |
| **Cursor** | `agent acp` (also `cursor-agent`) | Detected, identity-checked | `agent login`, or `CURSOR_API_KEY` |
| **Muse** (experimental) | `muse acp` | Detected | `muse login` |
| **Antigravity** | `agy acp` | Detected | `agy` (Google account, Gemini Enterprise or API key) |
| **GitHub Copilot** (preview) | `copilot --acp` | Detected | `copilot login`, needs a Copilot plan |
| **Kimi Code** | `kimi acp` | Detected | `kimi login` |
| **Qwen Code** | `qwen --acp` | Detected | `qwen`, then `/auth` |

Umbra never downloads or installs any of the native CLIs (Kiro, Cursor, Muse, Antigravity, Copilot, OpenCode,
Kimi, Qwen), and never runs `npx`. OpenCode now also uses `userInitiated` sign-in (`opencode auth login`);
Umbra never copies its provider configuration.

### Installing

- **Kiro**: install Kiro CLI from kiro.dev/cli. The installer puts `kiro-cli` in `~/.local/bin`.
- **Cursor**: install Cursor CLI from cursor.com/cli (`~/.local/bin/agent` and `cursor-agent`, linked into
  `~/.local/share/cursor-agent/`), or Homebrew's `cursor-cli` cask.
- **Muse**: install Muse Code. `muse acp` is on by default; `muse acp --help` confirms it. If
  `MUSE_EXPERIMENTAL_ACP` is set to anything but `on`/`true`/`1`, or your organization turned ACP off,
  `muse acp` exits with code 5 ("not available in this build").

- **Antigravity**: install the CLI (`agy` in `~/.local/bin`). Its modes `default`, `accept-edits`, `plan` are approval
  policies and follow Umbra's permission chip. Never started with `--dangerously-skip-permissions`.
- **GitHub Copilot**: `brew install copilot-cli` or `npm install -g @github/copilot`. ACP is public preview; stdio only
  (no `--port`). Entitlements are GitHub's: an account without Copilot gets the agent's own error.
- **Kimi Code**: `uv tool install kimi-cli` (`~/.local/bin/kimi`). stdout is protocol only; stderr is never chat text.
- **Qwen Code**: `npm install -g @qwen-code/qwen-code`. Uses the stable `--acp`, never `--experimental-acp`.
- **OpenCode**: models and credentials stay in OpenCode's own configuration.

Not every CLI above could be verified on every machine (see the matrix below).

Then open Settings ▸ Agent ▸ Agents (or the agent menu in the chat header ▸ Add Agent), add the agent and
press **Allow**. Allow is the consent to start that program; nothing runs before it.

## Discovery

Discovery reads the filesystem only. It never starts an agent.

1. The login shell's `PATH` (asked once per process with `zsh -lc`, `IDELoginShellPath`), because an app
   started from the Dock does not inherit the terminal's `PATH`.
2. `/opt/homebrew/bin` and `/usr/local/bin` (Apple silicon and Intel Homebrew).
3. Each agent's installer folder, `~/.local/bin`, searched last.

**Cursor's `agent` is checked.** `agent` is a generic name: on a Mac with Grok's CLI installed, the first
`agent` on `PATH` is Grok's. Umbra follows symbolic links and accepts a file only when its real path is
Cursor's (`…/cursor-agent/…`, Homebrew's `cursor-cli` cask). Anything else is skipped, the search carries
on, and if only another program's `agent` exists the row says so ("Found “agent” at …, but it is not
Cursor's CLI…") instead of running it. `cursor-agent` is tried too.

Discovery refreshes when Settings or the agent menu opens, and when you press **Detect Again** in
Settings ▸ Agent ▸ Agents.

### Statuses

| Row says | Meaning |
|---|---|
| Installed | The executable was found. Nothing was run. |
| Not installed · *install hint* | Not found on `PATH` or in the installer folder. |
| Found “agent” at …, but it is not Cursor's CLI | A file with the name exists and is another program. |
| Authentication required · Run “… login” in Terminal | A connection test or a chat was told to sign in. |
| Connected | A chat's agent process is running now. |
| Error · … | The last test or chat failed; the agent's message and the last lines of its stderr, scrubbed. |

"Authentication required" and "Connected" come only from a real handshake (the **Test** button or a
chat), never from a guess.

### Your own executable

**Edit** on a row takes any command line, for example `/Users/me/bin/kiro-cli acp --agent reviewer` or
`kiro-cli acp --agent-engine=v3`. A row you typed is run exactly as typed (no identity check: you chose
it), and it keeps the provider's rules below. Settings ▸ Agent stores rows as `IDEACPDefinition`
(`name`, `command`, `args`, `env`, `presetID`, `launchMode`); there is no separate JSON file to edit.
Secret environment values (for example `CURSOR_API_KEY`) go in the row's secret editor and are kept
in the Keychain (`acp.<row id>.<KEY>`), never in `UserDefaults` or a transcript.

## Signing in

Kiro, Cursor and Muse sign in with their own CLI. Umbra does not collect credentials and **never starts
a login flow on its own** for them (`ACPAuthenticationPolicy.userInitiated`): when the agent says
authentication is needed, the chat shows

> Muse needs you to sign in. *(the agent's own message, for example a device link and code)* Run “muse
> login” in Terminal, then send your message again.

and the agent row and header show "Authentication required". After signing in, send again (the agent is
restarted) or press **Test**. Cursor also accepts `CURSOR_API_KEY` / `CURSOR_AUTH_TOKEN` as row secrets.

Claude Code and Codex keep their earlier behavior (`automatic`): Umbra calls `authenticate` with the
agent's first method when `session/new` asks for it.

## Sessions

- **One process per chat**, started at the first message in the project folder (`cwd`), in its own
  process group. Stop sends `session/cancel`; closing the chat or window, Restart Agent, a provider
  switch on an empty chat and quitting end the process group and reap it.
- **Restoring**: a chat remembers its agent's session id. On the next start Umbra calls `session/load`
  only when the agent advertised `loadSession` (Kiro, Cursor and Muse all do) and only for the same
  command and project; a stale id starts a new session with a notice. Muse needs session logging for
  this (it is off with `muse acp --no-session-log`).
- **Switching providers** never moves a conversation: a chat with messages keeps its agent; choosing
  another agent opens another chat. Session ids are never reused across agents.

## What each agent gets

Capabilities come from the agent's `initialize` and `session/new` answers at run time, never from a
built-in list. Measured against the installed CLIs on 2026-11-16.

| | Kiro 2.24.1 | Cursor 2026.11.05 | Muse 1.4.20 |
|---|---|---|---|
| Auth methods advertised | none (signed in) | `cursor_login` | `muse-login` |
| `session/load` | yes | yes | yes (also `resume`, `list`) |
| Agent modes chip | `kiro_default`, `kiro_planner`, `kiro_guide` | Agent, Plan, Ask | 4 approval modes |
| Model picker | from `models` (`session/set_model`) | from `models` (`session/set_model`) | `model` config option |
| Other options | – | – | – (mode option shown on the mode chip) |
| Uses Umbra's fs/terminal | not observed | not observed | no (reads the disk itself) |
| Provider extensions | `_kiro.dev/*` ignored | `cursor/*` handled | – |
| Images in prompts | advertised | advertised | advertised |

Umbra advertises `fs.readTextFile`, `fs.writeTextFile` and `terminal` to every agent and serves them
through the project jail, unsaved buffers, checkpoints and the permission policy. An agent that reads
the disk itself (Muse) does not see unsaved edits.

### Verification status of the 2026-11-16 additions

| | Antigravity | Copilot | OpenCode | Kimi | Qwen |
|---|---|---|---|---|---|
| Catalog, command, discovery (mocked, deterministic) | yes | yes | yes | yes | yes |
| Real `initialize` + `session/new` | **yes**, agy 1.5.3 | not installed here | not installed here | not installed here | not installed here |
| Auth methods advertised | `oauth-personal`, `oauth-business`, `gemini-api-key`, `agent-platform` | unverified | unverified | unverified | unverified |
| `session/load` / resume / list | yes / yes / yes | unverified | unverified | unverified | unverified |
| Modes | default, accept-edits, plan (mapped) | unverified | unverified | unverified | unverified |
| Models | `models` + `model` option, plus `thought_level` | unverified | unverified | unverified | unverified |
| Images / embedded context | yes / yes | unverified | unverified | unverified | unverified |
| Prompt turn against a real account | not run | not run | not run | not run | not run |

Run the free handshakes with `UMBRA_LIVE_ACP_NATIVE=1 swift test --package-path Umbra --filter NativeACPLiveTests`;
the CLIs that are missing skip. The mock-based conversation tests cover Kiro, Cursor and Muse only; the new
five rely on the same generic runtime and catalog tests.

### Permissions and modes

Umbra's permission chip (Manual, Accept Edits, Auto, Plan) always gates what goes through Umbra: file
writes, terminals and `session/request_permission` cards (Plan rejects them without a card).

Some agents run tools themselves, so for them the permission mode is also applied as the agent's own
mode, when the agent advertised that mode (`IDEACPAdapterEntry.permissionModeMap`):

- **Muse** starts in `allowAll` ("Run every action without asking"). Umbra moves it before the first
  prompt: Manual and Accept Edits → `promptUnmatched`, Auto → `onRequest`, Plan → `denyUnmatched`.
  You can still choose `allowAll` on Muse's mode chip.
- **Cursor**: Plan → `plan`; leaving Plan returns Cursor to `agent`. Ask, or any mode you pick on
  Cursor's chip, is kept.
- **Kiro**'s modes are agent configurations, not approval policies, so they are left as you pick them.

### Cursor extension methods

| Method | Umbra |
|---|---|
| `cursor/ask_question` | One question card per question (options as buttons). The answer is matched to an option by label or id; a typed answer that is no option goes back as `skipped` with the text as the reason. Skip → `skipped`. |
| `cursor/create_plan` | The plan card (Approve · Accept Edits / Manual, Keep Planning) and the checklist. Approve → `accepted`; Keep Planning → `rejected` with your words. |
| `cursor/update_todos` | The checklist (`merge` respected; cancelled items show as done, marked "(cancelled)"). |
| `cursor/task` | A tool row "Subagent: …" with its arguments. Cursor runs the subagent. |
| `cursor/generate_image` | A tool row "Generate image: …". |

Every blocking request is answered. Stop, a disconnect, or no answer within 5 minutes answers
`cancelled` and the card says why. A question that arrives when no run is on screen is `cancelled` at
once. `cursor/task` and `cursor/generate_image` are documented as notifications; if one arrives as a
request it is answered `rejected` ("Umbra shows this request but cannot run it") rather than left open.

Unknown methods from any agent: a request is answered `-32601 Method not found`, a notification is
ignored. Kiro's `_kiro.dev/*` notifications (slash command lists, MCP OAuth URLs, compaction status) are
ignored today.

## Troubleshooting

- **"Not installed" but it works in Terminal**: press Detect Again. If the CLI lives somewhere unusual,
  Edit the row and give the full path (`command -v kiro-cli` prints it).
- **Cursor says another program's `agent` was found**: install Cursor CLI, or Edit the row to the full
  path of Cursor's `agent` (`~/.local/bin/agent` usually).
- **Authentication required**: run the login command shown (`kiro-cli login`, `agent login`,
  `muse login`) in Terminal, then send again or press Test.
- **Muse exits at once**: run `muse acp` in Terminal. Exit code 5 means the ACP gate is closed
  (`MUSE_EXPERIMENTAL_ACP`, remote or enterprise config); 3 means settings or credentials failed to load;
  2 means an argument was refused (approval flags and `-c permissions.*` are refused on purpose).
- **Kiro uses the wrong harness**: add `--agent-engine=v2` (or `v3`) to the row's command, or run
  `kiro-cli settings acp.agentEngine v3`. Kiro's logs: `$TMPDIR/kiro-log/kiro-chat.log`
  (`KIRO_LOG_LEVEL=debug` as a row environment value for more).
- **An agent stops answering**: Restart Agent in the chat header kills the process; the next message
  starts a new one and restores the session when the agent supports it.

## Design decisions

- **One runtime, provider data in the catalog.** Framing, correlation, sessions, cancellation,
  streaming, permissions and timeouts are AgentKit's `ACPConnection` and `ACPClientSession`. A provider
  is a catalog entry (`IDEACPAdapterCatalog`): command and alternates, extra search folders, an identity
  check, login command, auth policy, extension handlers and the permission-to-mode map. No provider
  subclasses, no second client.
- **Extensions cannot change standard methods.** `ACPClientExtension` is consulted only for methods the
  session does not implement, and interacts with the user only through session calls that are bounded by
  Stop, disconnects and the timeout.
- **Models are capability-driven.** `session/set_model` is sent only for a model the agent advertised in
  `models`. An agent that offers the model as a config option gets that option instead, never both.
- **No login flow without the user.** New providers use `userInitiated`; `ACPClientSession.authenticate
  (methodId:)` exists for an explicit Sign In and is not wired to a button yet.
- **Identity over names.** A generic command name is accepted only when its resolved path belongs to the
  provider; a custom path the user typed is trusted as typed.

## Tests

- AgentKit `ACPProviderExtensionTests` (scripted in-memory agent): models and `set_model`, the
  user-initiated auth policy, unknown methods, every Cursor extension including Stop, disconnect,
  timeout, no-run and wrong-session cases.
- Umbra `IDEACPNativeProviderCatalogTests` (no process): catalog, discovery and Cursor's identity check,
  mode mapping, sign-in text. `IDEACPNativeProviderConversationTests`: real chats over a Python mock of
  each provider built from the CLIs' captured handshakes (streaming, models, modes, Muse leaving
  `allowAll` before the first prompt, Cursor question and plan cards, signed-out Muse, the connection
  test, process cleanup).
- Opt-in live (`NativeACPLiveTests`): `UMBRA_LIVE_ACP_NATIVE=1` runs `initialize` + `session/new` against
  the installed CLIs (free); adding `UMBRA_LIVE_ACP_NATIVE_PROMPT=1` sends one short prompt per agent on
  your account.
