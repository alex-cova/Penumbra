# Harness gap 1: MCP beyond local stdio servers

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** open. Phases 1 and 2 are the useful core; the rest can wait.

## What exists today

- **Transport is already abstracted.** `MCPClient(transport: any ACPTransport, …)` (`Packages/AgentKit/Sources/AgentKit/MCP/MCPClient.swift`) speaks newline-delimited JSON-RPC over `ACPTransport` (`ACP/ACPTransport.swift`: `send(_ line: Data)`, `incoming: AsyncStream<Data>`, `close()`). AgentKit never spawns a process.
- **The host supplies the transport.** `MCPHub.TransportFactory = (MCPServerConfig) throws -> any ACPTransport` (`MCP/MCPHub.swift`). Umbra's factory is a closure in `IDEMCPManager` that builds `IDEACPTransport` (`Umbra/Sources/Umbra/Agent/ACP/IDEACPTransport.swift`, SubprocessKit, lazy spawn, process group).
- **Config is stdio-only.** `MCPServerConfig` has `name, command, args, env`. `MCPConfig.parse` reads `mcpServers` (or `servers`) and per entry `type`, `url`, `command`, `args`, `env`. A `url` or a `type` other than `stdio` skips the server with "It connects over …, and this version only starts local programs." The `url` value is never stored and `headers` is never read.
- **Where config lives.** Project: `.umbra/mcp.json` and `.mcp.json` (`IDEMCPProjectConfig.fileNames`, symlinks refused, first file to name a server wins). User servers are added in Settings and stored in UserDefaults (`umbra.agent.mcpServers`) with env secrets in the Keychain (`IDEMCPStore.account` gives `mcp.<uuid>.<KEY>`, through `IDEAgentKeyStore`).
- **Trust.** `IDEMCPManager.prepare(root:provider:confirm:willStart:)` asks once per project server; `IDEMCPStore.fingerprint(of:)` is a SHA-256 of the canonical config text, and `trusted`/`declined` sets persist in UserDefaults. A changed config asks again. The sheet is `IDEWorkspace.agentConfirmMCPServers` (Allow / Not Now).
- **Protocol coverage: tools only.** Sends protocol version `2025-06-18` (accepts `2025-03-26` and `2024-11-05`), client capabilities `{}`. Server requests other than `ping` get `methodNotFound`. The client never calls `ACPConnection.setNotificationHandler`, so `notifications/tools/list_changed` is dropped; `MCPHub` fixes its tool list when `start()` returns. Resource and prompt methods are not used.
- **Safety.** Every result goes through `UntrustedContent.wrap(…, source: "mcp:<server>")` after a 30,000-character head-and-tail cut. `MCPTool` is `.command` risk, so it asks unless a rule allows it. `MCPGateway` (`tool_search` + `tool_call`) and `ToolTrimming` keep the tool-definition cost down (`docs/AGENT_TOOL_LOADING_PLAN.md`). A server that dies restarts at most 3 times.
- **No OAuth anywhere** in the repo (no PKCE, no `ASWebAuthenticationSession`).

## Gap

Hosted MCP servers (Sentry, Linear, GitHub, Atlassian, Stripe and similar) cannot be used. Their config entries are skipped. There is also no way to keep a server's tool list fresh, and prompts and resources are unreachable.

## What Claude Code and OpenCode do

- Three transports: stdio, streamable HTTP, SSE (legacy).
- OAuth for remote servers, with the token kept in the keychain.
- MCP prompts become slash commands; resources are `@`-mentionable.
- A status list per server (connected, needs sign-in, failed) and live `tools/list_changed` handling.

## Proposal

1. **Transport enum in the config.** `MCPServerConfig` becomes `.stdio(command, args, env)` or `.http(url, headers)`. `MCPConfig.parse` keeps `url` and `headers`. The canonical text behind `IDEMCPStore.fingerprint(of:)` includes them, so a changed URL asks for trust again. Files: `MCP/MCPConfig.swift`, `IDEMCPStore.swift`, `IDEMCPSettingsSection.swift` (a URL field and header rows).
2. **`MCPHTTPTransport: ACPTransport`** in AgentKit (`MCP/`), on `URLSession`: POST each outgoing message, accept either a JSON body or an SSE body and push each message into `incoming`, carry the `Mcp-Session-Id` header, send `DELETE` on close. Umbra's `TransportFactory` switches on the enum. Header values (API tokens) are stored like env secrets (`IDEMCPStore.account`, Keychain). This alone covers every hosted server that takes a token. The host is fixed by the config: no redirect to another host.
3. **OAuth with PKCE** in Umbra, through `ASWebAuthenticationSession` (public API, App Store-safe), tokens in `IDEAgentKeychain`. AgentKit gets a token-provider closure on `MCPHTTPTransport` and retries once on 401. Dynamic client registration where the server offers it.
4. **`list_changed`.** Set the notification handler in `MCPClient`; `MCPHub` refreshes that one server's tools at the next turn boundary. The tool list is part of the session fingerprint, so a refresh starts a new `AgentSession` with the history kept (the existing behaviour for fingerprint changes).
5. **Prompts and resources.** Prompts through `IDEAgentCommandCatalog` as `/mcp__server__prompt`; resources through `IDEAgentMentionResolver` as `@` mentions. Resource text is untrusted content like tool output.
6. **Status.** `IDEMCPSettingsSection` shows connected, needs sign-in or failed (with the error) per server.

## Rules to keep

- AgentKit stays Foundation-only and never spawns a process. A remote server is a network feature the user turns on per server (the existing trust prompt), never a default.
- MCP output stays untrusted. The gateway and trimming apply to remote servers too, since they tend to expose many tools.
- No token in a log, a transcript, the memory file or the session store. `IDEAgentOutputScrubber` stays in front of anything saved.

## Tests

- A fake streamable HTTP server in `Packages/AgentKit/Tests` (a `URLProtocol` stub): initialize, `tools/list`, `tools/call`, an SSE reply, a dropped connection, the session id header, a 401 then a retry.
- `MCPConfig` parsing tests for `url` + `headers`, and an `IDEMCPStore` test that a URL change changes the fingerprint (`Umbra/Tests/UmbraTests`).
- OAuth is tested through a stub token provider; the real flow is checked by hand against one hosted server.

## Done when

A hosted server with a bearer token lists and calls tools in a Code chat; changing its URL asks for trust again; a server that adds a tool shows it on the next turn without a restart.

## Size

Phases 1 and 2: M. OAuth: M. `list_changed`: S. Prompts and resources: S each.

## Open questions

- Is SSE (the legacy transport) worth building, or only streamable HTTP?
- Should user-level remote servers live in the Keychain wholesale (URL included), or only the tokens?
