# Harness gap 4: image input

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** decision needed. The 2026-10-21 "text-only" decision removed text-to-image **generation**, and the plan lists "image pruning (AI mode is text-only)" under "Not planned". This doc is about image **input** (the user gives the model a picture). Confirm it is wanted before building.

## What exists today

- **Messages are text.** `ConversationItem` (`Packages/AgentKit/Sources/AgentKit/Messages/ConversationItem.swift`) has `.user(String)`, `.assistant(String)`, `.toolCall(id:name:arguments:)`, `.toolOutput(callID:output: String)` and `.opaque(OpaqueItem)`, with synthesized Codable. `@` attachments, browser notes, editor state and shell context are concatenated into the user string (block leads in `Messages/UntrustedContent.swift`).
- **Encoders, one per client.** Anthropic: `AnthropicRequestEncoder.messages(for:)` (a `{"type":"text"}` block; `tool_result` content is a string). OpenAI Responses: `ResponsesRequestEncoder.inputItem`. Chat Completions: `ChatCompletionsRequestEncoder.messages(for:)`. Ollama: `OllamaRequestEncoder.messages(for:)`. MLX: `MLXConversation.split`/`messages(_:)` (`Packages/AgentKitMLX`). Apple: `AppleTranscript.plan` (`Packages/AgentKitApple`).
- **No vision flag on the profile.** `ModelProfile` has `tier`, `editTolerance`, `preferredToolset`, `promptVariant`. Capability signals live elsewhere: `OllamaModelInfo.supportsVision` (`Ollama/OllamaModelCatalog.swift`), `ChatCompletionsCapabilities`, `LLMClient.supportsDisabledToolChoice`.
- **`read_file` on a PNG fails cleanly:** `DiskAgentWorkspace.readText` throws `notText` ("is not a UTF-8 text file"); files over 5 MB fail with `tooLarge`.
- **Composer.** `IDEAgentComposerField` registers `[.fileURL]` for drag and drop and `IDEAgentPanel` turns dropped files into `@` mentions (a file outside the project keeps its absolute path). Paste is plain text (`isRichText = false`, `importsGraphics = false`). No file picker.
- **Browser tools are text.** `browser_inspect` (`snapshot`, `text`, `element`, `console`, `network`, `annotations`, `annotate`) and `browser_act` (`IDEBrowserTools.swift`). The snapshot is a text outline with refs. `Umbra/Sources/Umbra/Agent/CLAUDE.md` lists screenshots as not built.
- **Budget.** `ContextBudget` (`Session/ContextCompaction.swift`) estimates UTF-8 bytes / 4 per item.
- **Redaction works on strings.** `IDEAgentOutputScrubber.scrub/shape` and `ToolContext.redactForMemory` take and return `String`.

## Gap

A user cannot paste a screenshot of a UI bug, and the agent cannot see a page it just changed in the Browser tab. Claude Code and OpenCode both accept images.

## What Claude Code and OpenCode do

Accept pasted, dragged or file-picked images in the prompt (when the model supports vision), downscale them, and can return images from tools (screenshots).

## Proposal

1. **Model.** Add `ConversationItem.userParts([UserPart])` where `UserPart` is `.text(String)` or `.image(id: String, mediaType: String)`. The existing `.user(String)` stays so saved chats still decode. Image bytes are written as files beside the session (`SessionStore` directory, 0600) and referenced by id; never inline in the JSON.
2. **Capability.** `LLMClient.supportsImages` (default false). Anthropic, OpenAI Responses and Chat Completions (per `ChatCompletionsCapabilities`) say yes; Ollama says yes only for models whose `supportsVision` is true. MLX and Apple stay text-only.
3. **Encoders.** Anthropic: an `image` block with a base64 `source`. Responses: `input_image`. Chat Completions: `image_url` with a data URL. Ollama: the `images` array. A client without support receives a text note in place of the image, never the bytes.
4. **Composer** (`Umbra/Sources/Umbra/Agent/Composer`). Paste and drop of image files become removable thumbnail chips when the model can see them; otherwise the existing `@` mention path runs and the composer says why. Add a file picker. Downscale to a bounded size (long edge about 1568 px) and re-encode before storing.
5. **Compaction.** `ContextBudget` counts an image as a fixed estimate; stage 1 of `ContextCompaction` replaces old images with a text note before it touches text.
6. **Later: images from tools.** `read_file` on an image file for a vision model, and a `browser_inspect` `screenshot` action (`WKWebView.takeSnapshot` is public API). Anthropic first: its `tool_result` content is a string today and needs a content-block array.

## Rules to keep

- Images from a web page, a tool or a dropped file are untrusted content.
- Never write image bytes to logs, the memory file or an export. `IDEAgentOutputScrubber` and `redactForMemory` must skip attachments rather than fail on them.
- A saved chat must stay loadable by an older build: only add cases, never change existing ones.

## Tests

Golden request JSON per encoder (`Packages/AgentKit/Tests`); `SessionStore` round trip with an image file; compaction drops images before text; a client without `supportsImages` gets the note; the composer refuses an image for a non-vision model (`Umbra/Tests/UmbraTests`).

## Done when

A screenshot dropped into a Code chat with a vision model is described correctly by the model; the same drop with a non-vision model keeps working as an `@` mention and says why; a chat with an image reloads after a relaunch.

## Size

L: model and store M, four encoders M, composer M, tool images M (later).

## Open questions

- Lift the text-only rule for input only, or keep AI mode text-only and add images to Code chats first?
- Should MLX vision models (Qwen-VL class) be in scope, or hosted providers only?
