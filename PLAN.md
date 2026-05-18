````markdown
# eclaw — Architecture & Development Plan

## Project Overview

eclaw is an Emacs-native AI coding agent written in Emacs Lisp.

Primary goals:

- learn how coding agents work internally
- build incrementally from scratch
- understand orchestration architecture
- remain modular and idiomatic to Emacs Lisp
- avoid premature abstraction and complexity

Current model backend:

- OpenRouter API
- model: `deepseek/deepseek-v4-flash`

---

# Current Features

## OpenRouter Integration

Implemented:

- API authentication via `OPENROUTER_API_KEY`
- HTTP requests using `url-retrieve-synchronously`
- JSON parsing using `json-read`
- UTF-8 decoding support

Current request endpoint:

```text
https://openrouter.ai/api/v1/chat/completions
```

---

# Current Architecture

## Conversation State

Current variable:

```elisp
(defvar eclaw-conversation nil)
```

Stores OpenAI/OpenRouter-style message objects:

```elisp
((role . "user")
 (content . "Hello"))
```

Current helper constructors:

- `eclaw-system-message`
- `eclaw-user-message`
- `eclaw-assistant-message`

---

## Message Building

Current flow:

```text
system prompt
+ conversation history
+ current user prompt
```

Implemented in:

```elisp
eclaw-build-messages
```

---

## Chat Pipeline

Current orchestration:

```text
user prompt
→ build messages
→ HTTP request
→ parse response
→ extract content
→ update conversation
→ log request/response
→ report token usage
→ render in *eclaw*
```

Primary entrypoints:

- `eclaw-chat`
- `eclaw-agent-chat`

---

## Logging

JSONL logging implemented.

Format:

- one JSON object per line
- includes:
  - timestamp
  - model
  - full request payload
  - full response payload

Log file:

```text
~/.emacs.d/eclaw-log.jsonl
```

---

# Important Bug Already Fixed

There were accidentally two definitions of:

```elisp
eclaw-build-messages
```

The duplicate definition removed conversation history.

Fix:

- remove duplicate definition
- preserve conversation inclusion

---

# Current Known Limitations

## Synchronous Requests

Current transport:

```elisp
url-retrieve-synchronously
```

Problem:

- freezes Emacs during requests

Future fix:

- migrate to async `url-retrieve`

---

## Global Conversation State

Current design:

```elisp
(defvar eclaw-conversation nil)
```

Problem:

- single shared session
- not buffer-local
- not project-local

Future direction:

```elisp
(defvar-local eclaw-conversation nil)
```

---

## Minimal UI

Current UI:

- append-only text rendering
- single `*eclaw*` buffer

No:

- dedicated major mode
- message rendering abstraction
- tool visualization
- navigation
- syntax highlighting

---

# Immediate Architectural Goals

## Refactor `eclaw-chat`

Current problem:

`eclaw-chat` performs too many responsibilities:

- transport
- orchestration
- parsing
- logging
- state mutation

Goal:

Separate layers cleanly.

---

# Planned Refactor

## 1. Transport Layer

Introduce:

```elisp
eclaw-send-request
```

Responsibility:

- HTTP requests only
- JSON encoding/decoding
- API communication only

No:

- state mutation
- rendering
- orchestration

Target structure:

```text
messages
→ request payload
→ HTTP
→ parsed response
```

---

## 2. Response Helpers

Introduce helpers:

```elisp
eclaw-get-message
eclaw-get-content
eclaw-get-tool-calls
eclaw-extract-usage
```

Reason:

Tool calling responses may not contain normal content.

---

## 3. Canonical Conversation State

Current approach:

```text
temporary prompt insertion
→ send request
→ persist afterward
```

Planned architecture:

```text
append message to conversation first
→ build request from conversation
→ send request
→ append assistant response
```

Conversation becomes canonical execution state.

---

# Tool Calling Roadmap

## Primary Goal

Add OpenAI/OpenRouter-compatible tool calling support.

---

# First Tool

Recommended initial tool:

```text
read_file(path)
```

Reason:

- deterministic
- easy to debug
- high utility
- safe compared to write/edit tools

---

# Additional tools (implemented)

- `list_directory(path, max_entries?, include_hidden?)` — bounded listing; drops entries whose resolved path is sensitive.
- `grep_files(root, pattern, glob?, max_matches?, max_files_scanned?, max_line_length?)` — literal substring search with match/file caps and a per-file byte ceiling (`eclaw-grep-max-file-bytes`).
- `notes_write_text(relative_path, content, append?)` — create or overwrite (or append when `append` is true) only `.txt` files under `<project-root>/notes/`, where the project root is the directory containing `.eclaw`; paths are validated with `file-truename` so targets cannot escape `notes/`.
- `skill_write(skill_dir, content)` — create or replace `.eclaw/skills/<skill_dir>/SKILL.md` only (`skill_dir` must match `[A-Za-z0-9_-]{1,64}`); clears `eclaw--skills-cache` after a successful write so the next completion picks up the skill index.

---

# Sensitive path policy (implemented)

- Customize via `eclaw-sensitive-path-prefixes` and `eclaw-sensitive-path-files` (`defcustom`).
- Enforced by `eclaw--path-sensitive-p` using `expand-file-name` + `file-truename` before any read/list/search touching disk.
- Shared denial text: `eclaw--sensitive-path-msg`.

---

# Planned Tool Flow

```text
user prompt
→ model requests one or more tools
→ Emacs executes each; one tool message per call
→ next model request(s) as needed
→ assistant final response (or stop if a safety cap fires)
```

---

# Planned Tool Message Types

## Assistant Tool Request

```json
{
  "role": "assistant",
  "tool_calls": [...]
}
```

## Tool Result Message

```json
{
  "role": "tool",
  "tool_call_id": "...",
  "content": "..."
}
```

---

# Planned Tool Infrastructure

## Tool Registry

Planned structure:

```elisp
(cl-defstruct eclaw-tool
  name
  description
  parameters
  function)
```

Possible future registry:

```elisp
(defvar eclaw-tool-registry ...)
```

---

## Tool Dispatcher

Future dispatcher:

```elisp
eclaw-dispatch-tool-call
```

Responsibilities:

- locate tool
- parse arguments
- execute tool
- return tool result message

Avoid:

- eval-based dispatch
- implicit execution

---

# Tool calling limits (safety)

Implemented in `eclaw.el`:

- Every `tool_calls` entry in an assistant message is executed and gets a matching `role: tool` message (parallel tool use in one turn is supported).
- The model may go through multiple completion rounds (tools, then reply, or more tools) until it returns a plain assistant message.
- Caps (both customizable via `defvar`): `eclaw-max-completions-per-prompt` (max HTTP round-trips per user message, default 32) and `eclaw-max-tokens-per-prompt` (cumulative `total_tokens` from each response `usage`, default 200000; exceeding it yields synthetic tool results and the turn ends).

Design intent:

- Allow multi-step tool use without unbounded cost or runaway loops.
- Stay inspectable: each round is logged; limits surface clear messages in the buffer and echo area.

---

# Future Milestones

## Milestone 1 — Tool Calling MVP

Deliver:

- tool schema support (including optional JSON parameters via `:optional` in `eclaw-deftool`)
- tool call parsing
- `read_file(path)` plus sensitive-path enforcement
- `list_directory(path, …)` and `grep_files(root, …)` with caps and the same policy
- tool result messages
- multi-tool and multi-round completions with configurable caps (`eclaw-max-completions-per-prompt`, `eclaw-max-tokens-per-prompt`)

---

## Milestone 1b — Project agent skills (Agent Skills index)

Deliver (project-local only, under `.eclaw/`):

- discover skills at `.eclaw/skills/<skill-name>/SKILL.md` only
- optional YAML frontmatter on `SKILL.md` with `name` and `description`
- append an **index-only** block to the system message (name, description, absolute path); bodies are not inlined
- cache invalidated when any discovered `SKILL.md` changes
- no global or user-wide skills paths (future extension)

---

## Milestone 2 — Session Isolation

Convert conversation state to buffer-local/project-local.

Goals:

- multiple simultaneous sessions
- project-specific agents
- isolated execution traces

---

## Milestone 3 — Major Mode

Create:

```text
eclaw-mode
```

Potential features:

- RET to send
- syntax highlighting
- message sections
- collapsible tool calls
- token stats
- replay support

---

## Milestone 4 — Async Transport

Replace:

```elisp
url-retrieve-synchronously
```

With:

```elisp
url-retrieve
```

Goals:

- non-blocking requests
- future streaming support
- responsive UI

---

## Milestone 5 — Streaming

Potential future support:

- token streaming
- incremental rendering
- live assistant output

Likely requires:

- async transport
- renderer abstraction

---

# Long-Term Architectural Direction

Desired layered architecture:

```text
UI Layer
↓
Orchestration Layer
↓
Conversation Runtime
↓
Tool Runtime
↓
Transport Layer
↓
Model API
```

---

# Important Design Philosophy

eclaw should remain:

- understandable
- inspectable
- hackable
- modular
- educational

Avoid:

- hidden magic
- premature autonomy
- excessive framework abstraction

The goal is to understand and build agent systems step-by-step.

---

# Suggested Future File Layout

```text
eclaw-core.el
eclaw-http.el
eclaw-conversation.el
eclaw-tools.el
eclaw-ui.el
eclaw-logging.el
eclaw-mode.el
```

---

# Key Architectural Insight

The system is transitioning from:

```text
chat client
```

to:

```text
LLM orchestration runtime
```

Conversation history becomes:

```text
execution trace
```

rather than simple dialogue history.

Tool calls are execution events.

This is the core architectural shift toward real coding-agent design.
````
