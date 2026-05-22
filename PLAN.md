# eclaw — Architecture & Development Plan

> **Keep this file current.** After any meaningful change to `eclaw.el` (features, limits, tools, milestones, or architecture), update this plan in the same session. Mark completed work as done, move stale “planned” items to “implemented” or delete them, and adjust “next steps” so the doc matches reality—not aspiration.

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
- model: `deepseek/deepseek-v4-flash` (`eclaw-model`)

Implementation: single file `eclaw.el` (~1,150 lines). Layers are documented in the file header; physical split into multiple files is still future work.

---

# Current Features

## OpenRouter integration

- API authentication via `OPENROUTER_API_KEY` or `eclaw-api-key`
- HTTP via `url-retrieve-synchronously` (blocking)
- Request construction: `eclaw--chat-request-payload`
- Transport: `eclaw--post-chat-completion` → `eclaw-get-response`
- JSON encode/decode; UTF-8 response bodies
- Endpoint: `https://openrouter.ai/api/v1/chat/completions`

## Conversation and orchestration

- **Canonical execution trace:** `eclaw-conversation` holds user, assistant (with optional `tool_calls`), and tool messages—no system row
- **Per-turn flow:** append user message → `eclaw-build-messages` → loop completions until plain assistant reply or a cap fires
- **Message builders:** `eclaw-system-message`, `eclaw-user-message`, `eclaw-assistant-message`, `eclaw-tool-message`
- **System prompt:** `eclaw-system-prompt` plus optional project skills index block
- **Entrypoints:** `eclaw-chat`, `eclaw-agent-chat`, `eclaw-reset-conversation`, `eclaw-explain-buffer`

## Tool calling (OpenAI/OpenRouter shape)

- Registry: `eclaw-deftool` macro → `eclaw--tool-registry` (hash table; not `cl-defstruct`)
- Optional parameters via `:optional` in `eclaw-deftool`
- Dispatch: `eclaw--dispatch-one-tool-call`, `eclaw--tool-result-messages`
- Multi-tool per turn; multi-round loop in `eclaw-chat`
- Toggle tools in requests: `eclaw-tools-enabled`
- Safety caps: `eclaw-max-completions-per-prompt`, `eclaw-max-tokens-per-prompt`

## Registered tools

| Tool | Role |
|------|------|
| `read_file` | Read file text; sensitive-path policy |
| `list_directory` | Bounded directory listing |
| `grep_files` | Literal substring search with caps; external grep/rg or Elisp fallback |
| `notes_write_text` | `.txt` only under `<project>/notes/` |
| `skill_write` | `.eclaw/skills/<dir>/SKILL.md` only |

## Project agent skills (Milestone 1b — done)

- Project root: directory containing `.eclaw` (`eclaw--skills-project-root`)
- Discover: `.eclaw/skills/<name>/SKILL.md` only
- YAML frontmatter: `name`, `description`; fallback from body
- System message: **index only** (name, description, path); bodies loaded via `read_file`
- Cache: `eclaw--skills-cache`, invalidated on mtime signature or `skill_write`

## Sensitive path policy

- `defcustom`: `eclaw-sensitive-path-prefixes`, `eclaw-sensitive-path-files`
- `eclaw--path-sensitive-p` before read/list/grep
- Denial: `eclaw--sensitive-path-msg`

## grep_files backend

- **`eclaw-grep-program`** (`defcustom`): `"grep"` (default), `"rg"`, or `nil` (Elisp only)
- **Primary:** `call-process` on GNU grep (`-rF -n -H -I`) or ripgrep (`--fixed-strings`, `--no-ignore`)
- **Fallback:** pure Elisp directory walk when the program is missing, exits non-zero, or `eclaw-grep-program` is `nil`
- **Security:** every match path is post-filtered through `eclaw--path-sensitive-p` (external tools can follow symlinks)
- **Semantics:** exhaustive search under `root` — **not** `.gitignore`-aware (ripgrep uses `--no-ignore` to match Elisp behavior)
- **Caps:** global match limit and line truncation apply to all backends; `max_files_scanned` is enforced only on the Elisp fallback

## Logging and UI

- JSONL: `eclaw-log` → `eclaw-agent-log-file` (default `~/.emacs.d/eclaw-log.jsonl`)
- One line per HTTP exchange: timestamp, model, request, response
- UI: append-only buffer `*eclaw*`; token usage in echo area via `eclaw-report-usage`

## Response helpers (implemented)

- `eclaw-get-first-choice`, `eclaw-get-message`, `eclaw-get-content`, `eclaw-get-tool-calls`, `eclaw-get-finish-reason`, `eclaw-extract-usage`
- `eclaw-get-content` falls back to `reasoning` when `content` is empty

---

# Current Architecture

## Layer map (logical; all in `eclaw.el` today)

```text
UI (*eclaw*, eclaw-agent-chat)
↓
Orchestration (eclaw-chat — loop, caps, state)
↓
Conversation runtime (eclaw-conversation, message builders)
↓
Tool runtime (registry, dispatch, handlers)
↓
Transport (eclaw--post-chat-completion, eclaw-get-response)
↓
OpenRouter API
```

## Conversation state

```elisp
(defvar eclaw-conversation nil)
```

Stores OpenAI/OpenRouter-style message alists, e.g.:

```elisp
((role . "user") (content . "Hello"))
((role . "assistant") (tool_calls . [...]))
((role . "tool") (tool_call_id . "...") (content . "..."))
```

**Canonical flow (implemented):**

```text
append user message to eclaw-conversation
→ eclaw-build-messages  ; [system] + conversation
→ HTTP + parse
→ on tool_calls: append assistant + tool results, rebuild messages, repeat
→ on plain content: append assistant reply, return
```

## Tool turn flow (implemented)

```text
user prompt
→ model may return tool_calls (one or many)
→ Emacs runs each tool → one role: tool message per call
→ next completion round as needed
→ final assistant text (or synthetic stop message if a cap fires)
```

## Tool message shapes (implemented)

Assistant with tools:

```json
{ "role": "assistant", "tool_calls": [...] }
```

Tool result:

```json
{ "role": "tool", "tool_call_id": "...", "content": "..." }
```

---

# Completed milestones

## Milestone 1 — Tool calling MVP ✓

- `eclaw-deftool` schema and optional parameters
- Tool call parsing and dispatch
- `read_file`, `list_directory`, `grep_files` with sensitive-path policy and caps
- `notes_write_text`, `skill_write` with path sandboxing
- Tool result messages; multi-tool and multi-round loop with caps

## Milestone 1b — Project agent skills ✓

- `.eclaw/skills/*/SKILL.md` discovery and index in system prompt
- YAML frontmatter; mtime-based cache invalidation
- No global/user-wide skill paths (extension point for later)

---

# Current known limitations

## Synchronous requests

- `url-retrieve-synchronously` freezes Emacs for each completion round
- **Next:** Milestone 4 — async `url-retrieve`

## Global conversation state

- Single `eclaw-conversation` for all buffers/projects
- **Next:** Milestone 2 — `defvar-local` or project-keyed sessions

## Minimal UI

- No `eclaw-mode`, tool visualization, navigation, or syntax highlighting
- **Next:** Milestone 3

## Monolithic source

- All layers in one file; transport not split from orchestration
- **Next:** transport extract + optional file layout (below)

---

# Upcoming work

## Immediate architectural goals

`eclaw-chat` still owns orchestration, logging, and state mutation alongside calling transport. Target: thin orchestration + dedicated transport function.

### 1. Transport layer (not done)

Introduce something like:

```elisp
eclaw-send-request  ; or rename eclaw--post-chat-completion when public
```

Responsibility: encode payload, POST, parse JSON, signal on HTTP/API errors—**no** conversation mutation, rendering, or tool dispatch.

```text
messages → request payload → HTTP → parsed response alist
```

Today: `eclaw--post-chat-completion` + `eclaw-get-response` (private, coupled to chat loop).

### 2. Session isolation — Milestone 2

```elisp
(defvar-local eclaw-conversation nil)
```

Or bind conversation to project root. Goals: multiple simultaneous sessions, per-project traces.

### 3. Major mode — Milestone 3

`eclaw-mode` on `*eclaw*`: RET to send, faces, sections, optional collapsible tool rounds, token stats.

### 4. Async transport — Milestone 4

Replace `url-retrieve-synchronously` with `url-retrieve` and callbacks. Prerequisite for responsive multi-round tool use and streaming.

### 5. Streaming — Milestone 5

Token streaming and incremental buffer updates; needs async transport and a small renderer abstraction.

### 6. Stronger edit tools (optional)

Bounded `write_file` / patch tool under the same path discipline as `notes_write_text`—not started; higher risk than read-only tools.

---

# Suggested future file layout

Still one file. When splitting, prefer:

```text
eclaw-core.el       ; orchestration, conversation
eclaw-http.el       ; transport
eclaw-conversation.el
eclaw-tools.el      ; registry, dispatch, handlers
eclaw-ui.el
eclaw-logging.el
eclaw-mode.el
```

---

# Historical note

Duplicate `eclaw-build-messages` once dropped conversation history; removed so history is always included in outgoing payloads.

---

# Design philosophy

eclaw should remain:

- understandable
- inspectable
- hackable
- modular
- educational

Avoid hidden magic, premature autonomy, and framework-heavy abstractions.

---

# Architectural stance (current)

The system **is** an LLM orchestration runtime, not a thin chat client.

- `eclaw-conversation` is an **execution trace** (user, assistant, tool events)
- Tool calls are **execution events** logged per HTTP round
- Project skills are **indexed capabilities** loaded on demand via `read_file`

Further evolution: async transport, isolated sessions, richer UI—without losing inspectability.
