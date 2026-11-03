// The host-independent agent pieces live in UmbraAgentSupport (Phase 1 of
// docs/harness/agent-harness-6.md): the provider factory, permission files, command
// runner/environment, output scrubber, sandbox, key store, and the headless `run_command`.
// Re-exported so existing code and tests keep resolving them through Umbra.
@_exported import UmbraAgentSupport
