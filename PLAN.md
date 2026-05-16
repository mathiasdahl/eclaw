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

# Planned Tool Flow

```text
user prompt
→ model requests tool
→ Emacs executes tool
→ tool result added to conversation
→ second model request
→ assistant final response
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

# Important Constraint

Initial scope intentionally limited.

Supported initially:

- single tool call
- single execution
- single followup response

Avoid initially:

- autonomous recursive loops
- multi-step agents
- self-directed planning

Reason:

keep orchestration understandable and debuggable.

---

# Future Milestones

## Milestone 1 — Tool Calling MVP

Deliver:

- tool schema support
- tool call parsing
- `read_file(path)`
- tool result messages
- second-pass completion

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
