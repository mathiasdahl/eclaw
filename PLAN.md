# eclaw — Architecture & Development Plan

> **Keep this file current.** After any meaningful change to `eclaw.el` (features, limits, tools, milestones, or architecture), update this plan in the same session. Mark completed work as done, move stale “planned” items to “implemented” or delete them, and adjust “next steps” so the doc matches reality—not aspiration.

## Project Overview

eclaw is a **personal AI assistant**—a general-purpose helper for everyday tasks (research, writing, planning, organization, and coding when needed). Coding support is one capability, not the product identity.

The **current implementation** is an Emacs-native orchestration runtime written in Emacs Lisp. Emacs is the first deployment target, not the defining scope of the project.

A **longer-term direction** is to run on a personal web site in the cloud: expose utilities there, persist data on that site, and assist from anywhere—not only inside Emacs. The same orchestration ideas (conversation trace, tools, skills) should carry over; only the runtime, transport, and storage backends would differ.

Primary goals:

- build a capable, inspectable personal assistant incrementally
- learn how LLM agent orchestration works internally
- understand orchestration architecture (conversation, tools, caps)
- remain modular and idiomatic to each runtime (Emacs Lisp today)
- avoid premature abstraction and complexity

Current model backend:

- OpenRouter API
- model: `deepseek/deepseek-v4-flash` (`eclaw-model`)

Implementation: single file `eclaw.el` (~1,270 lines). Layers are documented in the file header. **Decision:** keep one file for now; split only when the tradeoffs below justify it.

---

# Current Features

## OpenRouter integration

- API authentication via `OPENROUTER_API_KEY` or `eclaw-api-key`
- HTTP via `url-retrieve-synchronously` (blocking)
- Request construction: `eclaw-build-chat-payload`
- Transport: `eclaw-post-completion-request` → `eclaw-get-response`
- **All POSTs** go through internal gate `eclaw--http-post` (unibyte UTF-8 for body and headers); see [`docs/http-transport.md`](docs/http-transport.md)
- JSON encode/decode; UTF-8 response bodies
- Endpoint: `https://openrouter.ai/api/v1/chat/completions`

## Conversation and orchestration

- **Canonical execution trace:** `eclaw-conversation` holds user, assistant (with optional `tool_calls`), and tool messages—no system row
- **Per-turn flow:** append user message → `eclaw-build-messages` → loop completions until plain assistant reply or a cap fires
- **Message builders:** `eclaw-system-message`, `eclaw-user-message`, `eclaw-assistant-message`, `eclaw-tool-message`
- **System prompt:** `eclaw-system-prompt` plus optional project skills index block
- **Entrypoints:** `eclaw-chat`, `eclaw-agent-chat`, `eclaw-reset-conversation`, `eclaw-explain-buffer`, `eclaw-save-conversation`, `eclaw-list-conversations`, `eclaw-open-conversation`

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
| `list_directory` | Bounded directory listing (one level; not a glob search) |
| `grep_files` | Content search — ripgrep regex; default `files_with_matches`; gitignore-aware |
| `glob_files` | Find files by glob pattern (ripgrep `--files`; mtime-sorted) |
| `notes_write_text` | `.txt` only under `<project>/notes/` |
| `skill_write` | `.eclaw/skills/<dir>/SKILL.md` only |

## Search tools (Milestone 1c)

- **`glob_files`:** ripgrep `--files` with glob pattern; paths sorted by mtime (newest first); requires `rg`
- **`grep_files`:** ripgrep regex (GNU grep fallback for content / files_with_matches / count only); default `output_mode: files_with_matches`; respects `.gitignore` unless `include_ignored: true`
- **`list_directory`:** one-level listing (unchanged); not a substitute for `glob_files`
- **Security:** `eclaw--path-sensitive-p` on search root and every result path (post-filter after external search)
- **Backend:** `eclaw-grep-program` (`"rg"` default); caps via `head_limit` / `offset` / line truncation; `[eclaw: result limit N reached]` when truncated
- **Config:** `eclaw-rg-respect-gitignore`, `eclaw-rg-default-head-limit` (250), `eclaw-rg-max-head-limit` (1000), `eclaw-rg-max-pattern-length` (500)

## Project agent skills (Milestone 1b — done)

- Project root: directory containing `.eclaw` (`eclaw--skills-project-root`)
- Discover: `.eclaw/skills/<name>/SKILL.md` only
- YAML frontmatter: `name`, `description`; fallback from body
- System message: **index only** (name, description, path); bodies loaded via `read_file`
- Cache: `eclaw--skills-cache`; one directory scan builds mtime signature and skill list; invalidated on signature change or `skill_write`

## Sensitive path policy

- `defcustom`: `eclaw-sensitive-path-prefixes`, `eclaw-sensitive-path-files`
- `eclaw--path-sensitive-p` before read/list/grep/glob
- Denial: `eclaw--sensitive-path-msg`
- Post-filter on every path from `glob_files` / `grep_files` (including symlink targets via `file-truename`)

## Logging and UI

- JSONL: `eclaw-log` → `eclaw-agent-log-file` (default `~/.emacs.d/eclaw-log.jsonl`)
- One line per HTTP exchange: timestamp, model, request, response
- **Conversation archives:** Markdown files under `eclaw-conversation-archive-dir` (default `~/.emacs.d/eclaw/conversations/`); written on `eclaw-reset-conversation` (when non-empty) or `eclaw-save-conversation`; YAML frontmatter + `*eclaw*` transcript + optional collapsible tool appendix (`eclaw-archive-include-tools`); browse via `eclaw-list-conversations` (Dired) or `eclaw-open-conversation`
- UI: append-only buffer `*eclaw*`; token usage in echo area when `eclaw-debug` is non-nil
- Echo area: short tool-dispatch lines always; HTTP progress, token counts, and index reloads only when `eclaw-debug` is non-nil (`M-x eclaw-toggle-debug`, or `M-x customize-variable RET eclaw-debug RET`)

## Response helpers (implemented)

- `eclaw-get-first-choice`, `eclaw-get-message`, `eclaw-get-content`, `eclaw-get-tool-calls`
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
Transport (eclaw-build-chat-payload, eclaw-post-completion-request, eclaw--http-post, eclaw-get-response)
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

## Milestone 1c — Ripgrep-shaped search tools ✓

- Shared `eclaw--rg-*` layer (`call-process`, no shell); config defaults for gitignore, caps, pattern length
- **`grep_files` upgraded:** regex, `output_mode` (default `files_with_matches`), gitignore-aware, pagination, GNU grep fallback
- **`glob_files` added:** ripgrep `--files`, mtime sort, ripgrep-only
- System prompt exploration playbook; sensitive-path post-filter on all result paths
- Verified via batch checklist (May 2026): gitignore default, all output modes, regex/multiline, caps, fallback, symlink filter

## Transport layer refactor ✓

- Public API: `eclaw-build-chat-payload`, `eclaw-post-completion-request`
- Response parsing and accessors consolidated in `;;; HTTP transport` section (after tools, before orchestration)
- `eclaw-chat` uses transport layer; logging and usage display remain in orchestration
- Single POST gate: `eclaw--http-post` with unibyte UTF-8 encoding for body and headers (see [`docs/http-transport.md`](docs/http-transport.md))

---

# Known pitfalls

## Multibyte HTTP requests (regression-prone)

Emacs `url` rejects outgoing requests that contain multibyte strings. Encoding
only the JSON body is not enough—header values (e.g. `Authorization` built from
`getenv`) must be unibyte UTF-8 too. Symptom:

```text
Multibyte text in HTTP request: POST /api/v1/chat/completions HTTP/1.1
```

**Rule:** never set `url-request-data` or `url-request-extra-headers` outside
`eclaw--http-post`. Full write-up: [`docs/http-transport.md`](docs/http-transport.md).

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

- All layers in one file; logical transport layer extracted (physical split to `eclaw-http.el` deferred)
- **Next:** file split when transport section exceeds ~300 lines or async work begins

---

# Upcoming work

## Immediate architectural goals

Transport layer is extracted: `eclaw-chat` calls `eclaw-build-chat-payload` + `eclaw-post-completion-request`; logging and state mutation stay in orchestration.

### 1. Session isolation — Milestone 2

```elisp
(defvar-local eclaw-conversation nil)
```

Or bind conversation to project root. Goals: multiple simultaneous sessions, per-project traces.

### 2. Major mode — Milestone 3

`eclaw-mode` on `*eclaw*`: RET to send, faces, sections, optional collapsible tool rounds, token stats.

### 3. Async transport — Milestone 4

Replace `url-retrieve-synchronously` with `url-retrieve` and callbacks. Prerequisite for responsive multi-round tool use and streaming.

### 4. Streaming — Milestone 5

Token streaming and incremental buffer updates; needs async transport and a small renderer abstraction.

### 5. Stronger edit tools (optional)

Bounded `write_file` / patch tool under the same path discipline as `notes_write_text`—not started; higher risk than read-only tools.

---

# Source file layout (single file for now)

**Stay in `eclaw.el`** while the codebase is small and changes often span layers (orchestration + transport + tools). Revisit splitting when:

- work repeatedly targets **one layer** (tools, HTTP, skills) without touching the rest
- individual sections grow past **~300–400 lines**
- **parallel** feature work would benefit from separate files

When splitting, prefer **coarse files aligned to the section headers** in `eclaw.el`—not many tiny modules. Name files predictably so `PLAN.md` and grep route agents (and humans) to the right place; watch Elisp `require` order and macro/registry load order (`eclaw-deftool` before tool definitions).

**Suggested first cut** (matches current layers; highest ROI is `eclaw-tools.el`—registry + handlers, ~650 lines today):

```text
eclaw.el            ; config, conversation builders, orchestration, UI, requires
eclaw-tools.el      ; eclaw-deftool, registry, dispatch, all tool implementations
eclaw-http.el       ; request payload, POST, response parsing, accessors
eclaw-skills.el     ; project skills index (optional; ~170 lines today)
```

Later, if needed:

```text
eclaw-ui.el
eclaw-logging.el
eclaw-mode.el
```

**AI-assisted editing:** single file keeps cross-layer call chains in one read; coarse splits help focused tasks (add a tool, fix grep, change logging) by loading less irrelevant context per turn. Sweet spot is layer-sized files, not fine-grained fragmentation.

---

# Historical note

Duplicate `eclaw-build-messages` once dropped conversation history; removed so history is always included in outgoing payloads.

---

# Future direction (not implemented)

Cloud deployment on a personal web site:

- **Role:** same personal assistant, reachable outside Emacs (browser, API, or lightweight clients)
- **Utilities:** task-specific tools exposed as web-accessible capabilities (not limited to filesystem reads)
- **Data:** conversation history, notes, skills, and other durable state stored on the site—not only on the local machine
- **Architecture:** reuse the orchestration model (execution trace, tool dispatch, skills index); replace Emacs-specific I/O with HTTP handlers and site-local storage

Emacs remains a valid client/runtime; it is not the only one.

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

The system **is** an LLM orchestration runtime for a personal assistant, not a thin chat client. Today’s Emacs tools (filesystem read/search, notes, skills) are **local capabilities** suited to coding and project work; future cloud utilities will extend the same pattern with site-hosted storage and services.

- `eclaw-conversation` is an **execution trace** (user, assistant, tool events)
- Tool calls are **execution events** logged per HTTP round
- Project skills are **indexed capabilities** loaded on demand via `read_file`

Further evolution: async transport, isolated sessions, richer UI, and eventually a cloud-hosted runtime—without losing inspectability.
