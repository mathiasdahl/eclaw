# eclaw — Architecture & Development Plan

> **Keep this file current.** After any meaningful change to the eclaw sources (`eclaw.el`, `eclaw-*.el`, features, limits, tools, milestones, or architecture), update this plan in the same session. Mark completed work as done, move stale “planned” items to “implemented” or delete them, and adjust “next steps” so the doc matches reality—not aspiration.

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
- model: `deepseek/deepseek-v4-flash:nitro` (`eclaw-model`; list in `eclaw-available-models`)

Implementation: Emacs Lisp modules plus **`eclaw-web.el`** (optional web UI) and **`scripts/eclaw-web-push.py`**. Load core with `(require 'eclaw)`; web UI with `(require 'eclaw-web)`.

---

# Current Features

## OpenRouter integration

- API authentication via `OPENROUTER_API_KEY` or `eclaw-api-key`
- HTTP via `url-retrieve-synchronously` (blocking) in **`eclaw-http.el`**
- Request construction (**`tools` injection**): `eclaw-build-chat-payload` in **`eclaw.el`** (calls `eclaw-tool-definitions` in **`eclaw-tools.el`**)
- Transport (`eclaw-http.el`): `eclaw-post-completion-request` → `eclaw-get-response`
- **All POSTs** go through **`eclaw--http-post`** in **`eclaw-http.el`** (unibyte UTF-8 body and headers); see [`docs/http-transport.md`](docs/http-transport.md)
- JSON encode/decode; UTF-8 response bodies
- Endpoint: `https://openrouter.ai/api/v1/chat/completions`

## Conversation and orchestration

- **Canonical execution trace:** `eclaw-conversation` holds user, assistant (with optional `tool_calls`), and tool messages—no system row
- **Per-turn flow:** append user message → `eclaw-build-messages` → loop completions until plain assistant reply or a cap fires
- **Message builders:** `eclaw-system-message`, `eclaw-user-message`, `eclaw-assistant-message`, `eclaw-tool-message`
- **System prompt:** `eclaw-system-prompt` (global persona and cross-cutting rules only) plus optional agent skills index block plus **session context block** (session-start date only, frozen for the chat session; wall-clock time via `get_datetime`; see [`docs/session-context.md`](docs/session-context.md)). Per-tool purpose, constraints, and workflow live in `eclaw-deftool` descriptions (API `tools` array), not duplicated in the system prompt.
- **Session start:** `eclaw--ensure-session-started` in `eclaw-chat` sets `eclaw--session-started` on first turn; cleared by `eclaw-reset-conversation`
- **Entrypoints:** `eclaw-chat`, `eclaw-agent-chat`, `eclaw-reset-conversation`, `eclaw-explain-buffer`, `eclaw-save-conversation`, `eclaw-list-conversations`, `eclaw-open-conversation`, `eclaw-list-archived-conversations`, `eclaw-restore-conversation`

## Tool calling (OpenAI/OpenRouter shape)

- Registry: `eclaw-deftool` macro → `eclaw--tool-registry` in **`eclaw-tools.el`** (hash table; not `cl-defstruct`); plist includes `:risk` (`:read` default, `:write` for disk writes)
- Optional leading options in `eclaw-deftool`, e.g. `(:risk :write)`, before tool body
- **Tool approval** (complete): **`eclaw-tool-approval-mode`** (`off` / `writes` / `all`; default **`all`**), interactive/batch gate, transcript lines in **`*eclaw*`**, persisted rules in **`<eclaw-folder>/tool-approval-rules.el`** (global and args-scoped keys; **`remember`** / **`remember-exact`**); maintenance: **`eclaw-list-tool-approval-rules`**, **`eclaw-remove-tool-approval-rule`**, **`eclaw-clear-tool-approval-rules`** — see [`docs/tool-approval.md`](docs/tool-approval.md)
- Optional parameters via `:optional` in `eclaw-deftool`
- **Tool descriptions:** each `eclaw-deftool` top-level description carries per-tool guidance sent in the API `tools` array; avoid duplicating that text in `eclaw-system-prompt`
- Dispatch: `eclaw--dispatch-one-tool-call`, `eclaw--tool-result-messages` (**`eclaw-tools.el`**)
- Multi-tool per turn; multi-round loop in `eclaw-chat`
- Toggle tools in requests: `eclaw-tools-enabled`
- **Tool policy:** per-tool enable matrix in `<eclaw-folder>/tool-policy.el`; filters `eclaw-tool-definitions` and dispatch; web UI via `GET/PATCH /api/settings` — see [`docs/tool-policy.md`](docs/tool-policy.md)
- Safety caps: `eclaw-max-completions-per-prompt`, `eclaw-max-tokens-per-prompt`

## Registered tools

| Tool | Role | `:risk` (Slice A) |
|------|------|-------------------|
| `read_file` | Read file text with optional `offset`/`limit` line range; sensitive-path policy; default 250-line cap | `:read` |
| `buffer_read` | Read live Emacs buffer text (unsaved content); optional `offset`/`limit`; buffer deny list + sensitive file policy | `:read` |
| `emacs_context` | Session orientation: Emacs version, current buffer metadata, open buffer list; sensitive buffers omitted from listing | `:read` |
| `get_datetime` | Current wall-clock date/time; session date is in system message | `:read` |
| `describe_symbol` | Programmatic `C-h f` / `C-h v` / key lookup; documentation and arglist only (no variable values) | `:read` |
| `apropos` | Search symbols by regexp; one-line doc summaries only (no values) | `:read` |
| `list_directory` | Bounded directory listing (one level; not a glob search) | `:read` |
| `grep_files` | Content search — ripgrep regex; default `files_with_matches`; gitignore-aware | `:read` |
| `glob_files` | Find files by glob pattern (ripgrep `--files`; mtime-sorted) | `:read` |
| `web_search` | Live web search (Jina by default; provider registry) | `:read` |
| `web_fetch` | Fetch URL content as text (SSRF guard; Jina Reader by default) | `:read` |
| `send_email` | Send email to configured work or home address only (`mailme-mail` backend) | `:write` |
| `send_push` | Send Web Push to subscribed browsers (`eclaw-notify-send`) | `:write` |
| `notes_write_text` | `.txt` only under `<eclaw-folder>/notes/` | `:write` |
| `skill_write` | `<eclaw-folder>/skills/<dir>/SKILL.md` only | `:write` |
| `preferences_append` | Append one bullet to `<eclaw-folder>/preferences.md` | `:write` |
| `preferences_write` | Replace `<eclaw-folder>/preferences.md` | `:write` |
| `eval_elisp` | Full Elisp eval in running Emacs; disabled by default via tool policy | `:dangerous` |

## Runtime eval (Milestone — done)

- **`eval_elisp`:** `(eval form t)` in the running session; timeout and code-length caps; **disabled by default** in `tool-policy.el`
- **Module:** **`eclaw-eval.el`**; `:dangerous` risk (gated under `writes` / `all` approval modes)
- **Config:** `eclaw-eval-timeout-seconds` (30), `eclaw-eval-max-code-length` (32768)
- **Smoke:** `scripts/smoke/eval-elisp.el` — policy off/on, `(+ 1 2)` → `result=3`

## Tool policy (Milestone — done)

- **File:** `<eclaw-folder>/tool-policy.el` — `(tool-name . enabled)` alist
- **API:** `eclaw-tool-policy-enabled-p`, `eclaw-tool-policy-set`, `eclaw-tool-policy-apply-updates`, `eclaw-tool-policy-list`
- **Defaults:** all tools enabled except `eval_elisp`; `web_search`/`web_fetch`/`send_email` seeded from module `defcustom`s on first use
- **Web:** `GET/PATCH/POST /api/settings` in **`eclaw-web.el`**; settings panel in **`web/chat.html`**
- **Docs:** [`docs/tool-policy.md`](docs/tool-policy.md)

- **`glob_files`:** ripgrep `--files` with glob pattern; paths sorted by mtime (newest first); requires `rg`
- **`grep_files`:** ripgrep regex (GNU grep fallback for content / files_with_matches / count only); default `output_mode: files_with_matches`; respects `.gitignore` unless `include_ignored: true`
- **`list_directory`:** one-level listing (unchanged); not a substitute for `glob_files`
- **Security:** `eclaw--path-sensitive-p` on search root and every result path (post-filter after external search)
- **Backend:** `eclaw-grep-program` (`"rg"` default) in **`eclaw-tools.el`**; caps via `head_limit` / `offset` / line truncation; `[eclaw: result limit N reached]` when truncated
- **Config:** `eclaw-grep-program`, `eclaw-rg-respect-gitignore`, `eclaw-rg-default-head-limit` (250), `eclaw-rg-max-head-limit` (1000), `eclaw-rg-max-pattern-length` (500) — all in **`eclaw-tools.el`**
- **`grep_files` line numbers:** only when `output_mode: content` (`filepath:linenum:content`); default `files_with_matches` returns paths only

## Web search tools (Milestone 1d — done)

- **`web_search`:** live web query via provider registry (Jina Search default); numbered title/URL/snippet results
- **`web_fetch`:** read a specific URL via Jina Reader; SSRF guard blocks localhost, `.local`, and private/metadata IPs before HTTP
- **Provider contract:** each provider implements search `(query max-results) -> string` and fetch `(url) -> string`; registry `eclaw--ws-provider-alist`; active provider `eclaw-web-search-provider` (default `'jina`)
- **Config:** `eclaw-web-search-enabled`, `eclaw-jina-api-key` (`JINA_API_KEY` env, optional), `eclaw-jina-search-url`, `eclaw-jina-reader-url`, result/fetch caps — all in **`eclaw-web-search.el`**
- **HTTP:** generic `eclaw--http-get`, `eclaw-http-read-response`, `eclaw-http-post-json` in **`eclaw-http.el`**

## Web Push notifications (Milestone 5 — done)

- **`eclaw-notify.el`:** subscription file, VAPID JSON, optional subscribe secret; `eclaw-notify-message` invokes **`scripts/eclaw-web-push.py`** (pywebpush) via `call-process`; **`send_push`** tool via `eclaw-notify-send`
- **`eclaw-chat`** calls **`eclaw-notify-chat-complete`** when a turn finishes (web, `*eclaw*`, batch); gated by **`eclaw-notify-on-chat-complete`**
- **Web UI:** bell button in **`web/chat.html`**; **`web/sw.js`**; **`GET /sw.js`**, **`POST/DELETE /api/push/subscribe`** in **`eclaw-web.el`**
- **Config:** `eclaw-notify-enabled`, `eclaw-notify-on-chat-complete`, `eclaw-notify-send-enabled`, `eclaw-notify-push-program`, `eclaw-notify-click-url`, `eclaw-notify-subscribe-secret`; storage under `<eclaw-folder>/push-*.json`

## Email tool (Milestone — done)

- **`send_email`:** send plain-text mail to configured **work** or **home** address only; recipient enum in JSON schema; `:write` risk
- **Backend:** user's personal `mailme-mail` (body address); not defined in eclaw
- **Config:** `eclaw-mail-enabled`, `eclaw-mail-work-address`, `eclaw-mail-home-address` — all in **`eclaw-mail.el`**
- **Smoke:** `scripts/smoke/send-email.el` (offline; stubs `mailme-mail`)

## read_file line ranges

- Optional **`offset`** (1-indexed start line; negative counts from EOF) and **`limit`** (max lines)
- Output prefixes each line with its line number (`123|content`); `[eclaw: line limit N reached]` when truncated
- **Config:** `eclaw-read-default-line-limit` (250), `eclaw-read-max-line-limit` (1000) in **`eclaw-tools.el`**

## Emacs introspection tools (Milestone 1e — done)

- **`buffer_read`:** read live buffer text (unsaved); optional `offset`/`limit`; numbered lines; `eclaw-sensitive-buffer-name-regexp-list` + `eclaw--buffer-sensitive-p` deny policy
- **`emacs_context`:** cheap session orientation — Emacs version, session start time, current buffer metadata (name, file, mode, modified, point/mark/region), open buffer list; sensitive buffers omitted from listing; optional `max_buffers` (default 20, cap 100)
- **`describe_symbol`:** programmatic help — `name` + optional `kind` (`function`, `variable`, `command`, `key`, `auto`); documentation, arglist, interactive form, custom type, source file; **never returns variable values**
- **`apropos`:** `(apropos-internal pattern)` with one-line doc summaries; optional `max_results` (default 30, cap 100)
- **Handlers:** `;;; Emacs introspection` section in **`eclaw-tools.el`**; shared cap helper `eclaw--introspect-effective-cap`
- **Smoke:** `scripts/smoke/buffer-read.el`, `scripts/smoke/emacs-context.el`, `scripts/smoke/describe-symbol.el` — wired in `scripts/eclaw-validate-elisp.sh`

## Agent skills (Milestone 1b — done)

- Root: `eclaw-folder` (`eclaw--folder`); default `~/.eclaw/`
- Discover: `skills/<name>/SKILL.md` only (**`eclaw-skills.el`**)
- YAML frontmatter: `name`, `description`; fallback from body
- System message: **index only** (name, description, path); bodies loaded via `read_file`
- Cache: `eclaw--skills-cache`; one directory scan builds mtime signature and skill list; invalidated on signature change or `skill_write`

## Sensitive path policy

- `defcustom`: `eclaw-sensitive-path-prefixes`, `eclaw-sensitive-path-files` (**`eclaw-tools.el`**)
- `eclaw--path-sensitive-p` before read/list/grep/glob (**`eclaw-tools.el`**)
- Denial: `eclaw--sensitive-path-msg`
- Post-filter on every path from `glob_files` / `grep_files` (including symlink targets via `file-truename`)

## Logging and UI

- **Data root:** `eclaw-folder` (default `~/.eclaw/`); all paths below are relative to it
- JSONL log: `eclaw-log.jsonl` (`eclaw--agent-log-file`)
- One line per HTTP exchange: timestamp, model, request, response
- **Conversation archives:** paired `.md` + `.json` under `conversations/`; written on `eclaw-reset-conversation` (when non-empty) or `eclaw-save-conversation` (Markdown only for manual save). Markdown: YAML frontmatter (`folder:` records `eclaw-folder`) + `*eclaw*` transcript + optional collapsible tool appendix (`eclaw-archive-include-tools`). JSON snapshot (v1): full `eclaw-conversation` trace (user, assistant with `tool_calls`, tool messages), session metadata, usage — written alongside Markdown on reset. Browse Markdown via `eclaw-list-conversations` (Dired) or `eclaw-open-conversation`; list/restore JSON via `eclaw-list-archived-conversations` and `eclaw-restore-conversation` (archives current session first if non-empty). **Web UI:** history panel lists snapshots; **Emacs restore UI** (beyond `M-x eclaw-restore-conversation`) deferred. Legacy Markdown-only archives are not restorable.
- UI: append-only buffer `*eclaw*`; token usage in echo area when `eclaw-debug` is non-nil
- Echo area: short tool-dispatch lines always; HTTP progress, token counts, and index reloads only when `eclaw-debug` is non-nil (`M-x eclaw-toggle-debug`, or `M-x customize-variable RET eclaw-debug RET`)

## Response helpers (implemented in **`eclaw-http.el`**)

- `eclaw-get-first-choice`, `eclaw-get-message`, `eclaw-get-content`, `eclaw-get-tool-calls`
- `eclaw-get-content` falls back to `reasoning` when `content` is empty

---

# Current Architecture

## Layer map (logical; **`eclaw-http.el`** = transport implementation)

```text
UI (*eclaw*, eclaw-agent-chat)
↓
Orchestration (`eclaw.el`: eclaw-chat — loop, caps, state)
↓
Conversation runtime (`eclaw.el`: eclaw-conversation, message builders)
↓
Tool runtime (`eclaw-tools.el`: registry, dispatch, handlers)
↓
Transport (`eclaw-http.el`: eclaw-post-completion-request, eclaw--http-post, eclaw-get-response, accessors)
  ; `eclaw-build-chat-payload' in `eclaw.el` (attaches `tools' from `eclaw-tools.el')
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
- `notes_write_text`, `skill_write`, `preferences_append`, `preferences_write` with path sandboxing
- Tool result messages; multi-tool and multi-round loop with caps

## Milestone 1b — Agent skills ✓

- `skills/*/SKILL.md` under `eclaw-folder` — discovery and index in system prompt
- YAML frontmatter; mtime-based cache invalidation
- No global/user-wide skill paths (extension point for later)

## Milestone 1c — Ripgrep-shaped search tools ✓

- Shared `eclaw--rg-*` layer (`call-process`, no shell); config defaults for gitignore, caps, pattern length
- **`grep_files` upgraded:** regex, `output_mode` (default `files_with_matches`), gitignore-aware, pagination, GNU grep fallback
- **`glob_files` added:** ripgrep `--files`, mtime sort, ripgrep-only
- System prompt exploration playbook; sensitive-path post-filter on all result paths
- Verified via batch checklist (May 2026): gitignore default, all output modes, regex/multiline, caps, fallback, symlink filter

## Milestone 1d — Web search (Jina) ✓

- Provider-ready **`eclaw-web-search.el`**: `web_search`, `web_fetch`; Jina Search + Reader; SSRF guard on fetch
- Generic HTTP helpers in **`eclaw-http.el`**: `eclaw--http-get`, `eclaw-http-read-response`, `eclaw-http-post-json`
- Offline smoke: `scripts/smoke/web-search.el` (URL policy + registry)

## Milestone 5 — Web Push notifications ✓

- **`eclaw-notify.el`**, **`scripts/eclaw-web-push.py`**, **`web/sw.js`**; subscribe API and bell UI in **`eclaw-web.el`** / **`web/chat.html`**
- Notify on **`eclaw-chat`** completion; pywebpush on server (not Elisp crypto)
- Smoke: `scripts/smoke/push-subscribe.el`

## Conversation restore ✓

- **Archive:** `eclaw-archive-current-conversation` writes `.md` + `.json` on reset (JSON failure aborts archive)
- **Read/list/restore:** `eclaw--conversation-read-snapshot`, `eclaw-list-archived-conversations`, `eclaw-restore-conversation` in **`eclaw.el`**
- **Web API:** `GET /api/conversations`, `POST /api/conversations/restore` in **`eclaw-web.el`**
- **Web UI:** history panel in **`web/chat.html`** (fetch list, confirm, restore, render messages)
- **Smoke:** `scripts/smoke/conversation-snapshot-write.el`, `scripts/smoke/conversation-restore.el`
- **Deferred:** richer Emacs UI for browsing/restoring archives (Dired on `.json`, dedicated buffer, etc.)

## Tool call approval ✓

Human-in-the-loop before local tools run, with persisted rules. Documented in [`docs/tool-approval.md`](docs/tool-approval.md). Slices A–F:

- **A** — `:risk` on tools; `eclaw-tool-approval-mode` / `eclaw--tool-call-would-require-approval-p`
- **B** — Interactive gate in `eclaw--dispatch-one-tool-call`; batch via `eclaw-tool-approval-noninteractive`
- **C** — `eclaw--tool-approval-transcript-line` in `*eclaw*`
- **D** — `tool-approval-rules.el`; global **`remember`**
- **E** — Args-scoped rule keys; **`remember-exact`**; `eclaw-list-tool-approval-rules`, `eclaw-remove-tool-approval-rule`, `eclaw-clear-tool-approval-rules`
- **F** — Multi-tool and cap behavior documented (one tool message per `tool_call_id`; synthetic results on token cap)

## Transport layer refactor ✓ (+ physical **`eclaw-http.el`** split, May 2026)

- Public API: `eclaw-build-chat-payload` (**`eclaw.el`**), **`eclaw-post-completion-request`** (**`eclaw-http.el`**)
- Parsing and accessors live in **`eclaw-http.el`**; **`eclaw.el`** loads **`(require 'eclaw-tools)`** then **`(require 'eclaw-http)`** before **`eclaw-build-chat-payload`**
- **`eclaw-chat`** unchanged: build payload → post → parse; logging and usage stay in orchestration
- Single POST gate: **`eclaw--http-post`** (unibyte UTF-8) — [`docs/http-transport.md`](docs/http-transport.md)

---

# Known pitfalls

## Multibyte HTTP requests (regression-prone)

Emacs `url` rejects outgoing requests that contain multibyte strings. Encoding
only the JSON body is not enough—header values (e.g. `Authorization` built from
`getenv`) must be unibyte UTF-8 too. Symptom:

```text
Multibyte text in HTTP request: POST /api/v1/chat/completions HTTP/1.1
```

**Rule:** never set `url-request-data` or `url-request-extra-headers` outside **`eclaw--http-post`** (**`eclaw-http.el`**). Full write-up: [`docs/http-transport.md`](docs/http-transport.md).

---

# Current known limitations

## Synchronous requests (intentional for now)

- `url-retrieve-synchronously` blocks Emacs for each completion round
- **Not a current goal:** async `url-retrieve` — synchronous behavior is acceptable; typical use is one agent task per session. Async may be revisited if multi-round tool use or streaming becomes painful

## Global conversation state

- Single `eclaw-conversation` for all buffers/projects
- **Next:** Milestone 2 — `defvar-local` or project-keyed sessions

## Minimal UI

- No `eclaw-mode`, tool visualization, navigation, or syntax highlighting
- **Next:** Milestone 3

## Multi-file layout ✓

- **`eclaw.el`** — orchestration spine (~650 lines): configuration, conversation, request assembly, chat loop, logging, UI
- **`eclaw-skills.el`** — agent skills index (~200 lines)
- **`eclaw-tools.el`** — tool registry, handlers, dispatch, path policy (~1,080 lines)
- **`eclaw-http.el`** — HTTP transport (~200 lines)
- **`eclaw-web-search.el`** — web search/fetch tools (~250 lines)

---

# Upcoming work

## Immediate architectural goals

Transport layer is extracted: `eclaw-chat` calls `eclaw-build-chat-payload` + `eclaw-post-completion-request`; logging and state mutation stay in orchestration.

### 1. Session isolation — Milestone 2

```elisp
(defvar-local eclaw-conversation nil)
```

Or bind conversation per buffer or per `eclaw-folder`. Goals: multiple simultaneous sessions, separate traces.

### 2. Major mode — Milestone 3

`eclaw-mode` on `*eclaw*`: RET to send, faces, sections, optional collapsible tool rounds, token stats.

### 3. Stronger edit tools (optional)

Bounded `write_file` / patch tool under the same path discipline as `notes_write_text`—not started; higher risk than read-only tools.

### 5. Web Push notifications — Milestone ✓

**Status:** done. Chrome **Web Push** for the browser chat UI: user-initiated subscribe, notifications with tab closed.

- **`eclaw-notify.el`** — subscription storage, `eclaw-notify-message`, `eclaw-notify-chat-complete` hook from `eclaw-chat`
- **`scripts/eclaw-web-push.py`** — pywebpush sender (VAPID + payload encryption; not Elisp)
- **`web/sw.js`** — service worker (`push`, `notificationclick`)
- **`web/chat.html`** — bell button, `Notification.requestPermission`, `pushManager.subscribe`
- **`eclaw-web.el`** — `GET /sw.js`, `POST/DELETE /api/push/subscribe`; `push_*` fields in `/api/settings`
- **Storage:** `<eclaw-folder>/push-subscriptions.json`, `<eclaw-folder>/push-vapid.json`
- **Smoke:** `scripts/smoke/push-subscribe.el` (`--smoke push-subscribe`)
- **Cloud setup:** generate VAPID keys, set `eclaw-notify-enabled`, `eclaw-notify-push-program` (venv Python), optional `eclaw-notify-subscribe-secret` — see **README.md**

#### Deployment context (reference)

- Web UI exposed at **`https://example.com/<secret-path>`** via reverse proxy (single user; URL obscurity acceptable).
- **`eclaw-web-base-path`** and **`ECLAW_WEB_BASE`** in **`web/chat.html`** / **`eclaw-web.el`** already support subpath deploys.
- **Always-on:** Emacs on the cloud server runs eclaw continuously once started — no separate push relay; Emacs sends pushes when work completes.
- **External tools OK:** Web Push crypto (VAPID JWT, payload encryption) must **not** be implemented in Elisp. Use Python (`pywebpush`), the Node `web-push` CLI, or any other suitable external tool installable on the cloud server. Prefer the simplest reliable option.

#### Server prerequisites (partial — cloud server, Jul 2026)

System Python on the cloud server was too old for **pywebpush** 2.x (requires Python ≥ 3.10). Installed via **[uv](https://docs.astral.sh/uv/)** instead of upgrading system Python:

- **uv** installed on the cloud server (same user as Emacs).
- Modern Python installed with uv (e.g. 3.12).
- Dedicated venv: **`~/.local/share/eclaw-venv`** with **`pywebpush`** installed (`uv pip install pywebpush` or pinned `pywebpush==2.3.0`).

**At implement time:** set **`eclaw-notify-push-program`** (or equivalent) to the venv interpreter, e.g. **`~/.local/share/eclaw-venv/bin/python3`** — use an **absolute path**; non-interactive Emacs may not have `uv` on `PATH`. Verify with:

```bash
~/.local/share/eclaw-venv/bin/python3 -c "from pywebpush import webpush; print('ok')"
```

**Operator setup on cloud server:** generate VAPID key pair, enable `eclaw-notify-enabled`, set `eclaw-notify-push-program` to venv Python (see **Server prerequisites** below). Outbound HTTPS to FCM/Mozilla push endpoints must be allowed.

**Why not Elisp crypto:** Emacs exposes digests/MACs/symmetric ciphers via GnuTLS but not ECDSA (ES256) signing or ECDH — both required for Web Push. No maintained Elisp Web Push library; **`jwt.el`** signs HMAC only, not ES256.

#### Architecture

```text
Browser → POST /api/push/subscribe → eclaw-web.el → push-subscriptions.json
eclaw-chat finishes → eclaw-notify.el → call-process → external push script → FCM → service worker → showNotification
```

#### Implemented files

| Piece | File | Notes |
|-------|------|-------|
| Service worker | **`web/sw.js`** | `push` + `notificationclick` → open chat URL |
| Subscribe UI | **`web/chat.html`** | Bell button; register SW at `${ECLAW_WEB_BASE}/sw.js` |
| Serve SW | **`eclaw-web.el`** | `GET /sw.js`; `Cache-Control: no-store` |
| Subscribe API | **`eclaw-web.el`** | `POST/DELETE /api/push/subscribe` → `push-subscriptions.json` |
| Notify module | **`eclaw-notify.el`** | `eclaw-notify-message`; VAPID/subscription paths; subscribe secret |
| Push sender | **`scripts/eclaw-web-push.py`** | Python + pywebpush via `call-process` |
| Hook | **`eclaw.el`** | `eclaw-notify-chat-complete` at end of `eclaw-chat` |
| VAPID keys | `<eclaw-folder>/push-vapid.json` | Generate once; private key never exposed to model |
| Docs | **`README.md`** | Setup: keys, enable, proxy notes for `sw.js` |
| Smoke | **`scripts/smoke/push-subscribe.el`** | Parse/store subscription JSON without live FCM |

#### External crypto (implementation stance)

- **Do not** implement Web Push signing/encryption in Emacs Lisp.
- **Do** thin Elisp wrapper (**`eclaw-notify.el`**) that passes title, body, subscription file, and VAPID key path to an external sender.
- Acceptable senders (pick one at implement time): Python + `pywebpush` (recommended default; **already on server in `~/.local/share/eclaw-venv`**), Node `web-push` CLI, or any maintained tool handling VAPID + `aes128gcm`.
- **`eclaw-notify-push-program`** (or similar) `defcustom` points at the venv Python (absolute path); see **Server prerequisites** above.

#### Security

- Subscriptions are device credentials — treat **`push-subscriptions.json`** as sensitive.
- Optional shared secret on subscribe POST (in init.el) to prevent subscription hijacking if secret URL leaks.
- Push **send** stays server-side only (Emacs → script → FCM); no public send endpoint.
- VAPID private key and subscribe secret not in skills or tool-exposed config.

#### Reverse proxy checklist (example.com)

- Proxy `/SECRETPATH/sw.js` and `/SECRETPATH/api/push/*` to Emacs web server.
- Pass full path prefix to Emacs (**`eclaw-web--strip-base-path`** expects it).
- Avoid aggressive caching of **`sw.js`**.

#### Out of scope for v1

- Multi-user auth
- Push when Emacs is not running (not a concern: cloud Emacs is always on)
- In-tab-only Notification API without service worker
- Pure-Elisp Web Push crypto
- **`notify_user`** agent tool (deferred)

### 4. Emacs introspection tools (read-only) — Milestone 1e ✓

**Status:** done (`buffer_read`, `emacs_context`, `describe_symbol`, `apropos`). Implemented bullets moved to **Current Features** above. Canonical spec below for reference. Historical brainstorming lives in [`notes/tool-discussion.txt`](notes/tool-discussion.txt).

#### Motivation

- `eclaw-system-prompt` already tells the model it runs inside Emacs, but filesystem tools (`read_file`, `grep_files`, …) are confined to `eclaw-folder` via `eclaw--tool-resolve-path` in **`eclaw-tools.el`**.
- `eclaw-explain-buffer` manually sends `(buffer-string)` to the chat; introspection tools let the model self-serve during tool loops.
- These tools are **not** subject to `eclaw-folder` confinement; they read the live Emacs session (buffers, point, symbols).

```text
Today:  read_file / grep_files  →  eclaw-folder only
1e:     buffer_read / emacs_context / describe_symbol  →  live Emacs session
```

#### Shared conventions

Reuse patterns from existing tools (`eclaw-deftool`, `eclaw-tool-read-file`, `eclaw--read-*` helpers in **`eclaw-tools.el`**):

| Concern | Convention |
|---------|------------|
| Risk tag | `:risk :read` (default) for all tools in this milestone |
| Approval | Gated under default `eclaw-tool-approval-mode` = `all` |
| Line output | Numbered lines (`123\|content`); same `offset` / `limit` semantics as `read_file` |
| Line caps | Reuse `eclaw-read-default-line-limit` (250) and `eclaw-read-max-line-limit` (1000), or add dedicated `defcustom`s if separation is preferred |
| Truncation footer | `[eclaw: line limit N reached]` / `[eclaw: listing truncated to N entries]` |
| Handler location | New `;;; Emacs introspection` section in **`eclaw-tools.el`** initially; split to **`eclaw-introspect.el`** only if the section grows large |
| Helpers | Factor shared line-range logic from `eclaw--read-*` rather than duplicating |
| System prompt | Global rules only in `eclaw-system-prompt` (`eclaw.el`); per-tool guidance in `eclaw-deftool` descriptions |

#### Tool 1: `buffer_read` ✓ (implement first)

**Purpose:** Read text from a live Emacs buffer, including unsaved content.

**Parameters:**

| Param | Type | Required | Notes |
|-------|------|----------|-------|
| `buffer` | string | optional | Buffer name; omit, empty, or `"current"` → `(current-buffer)` |
| `offset` | integer | optional | 1-indexed start line; negative counts from EOF (same as `read_file`) |
| `limit` | integer | optional | Max lines returned |

**Behavior:**

- Resolve buffer: `(get-buffer buffer)` or `(current-buffer)`; return error string if not live.
- Read with `with-current-buffer`; strip text properties (`substring-no-properties`).
- Split lines from in-memory string (same line splitting as `eclaw--read-split-lines`, but not from disk).
- Return numbered slice via `eclaw--read-format-lines` / `eclaw--read-resolve-start-line`.

**Safety / deny list:**

- Block buffers whose names match a configurable regexp list (suggested defaults): `^\*auth\*`, `^\*passwd\*`, `^epa-`, `^\*sudo\*`.
- Also block when `(buffer-file-name buf)` passes `eclaw--path-sensitive-p` (reuses SSH/credential policy for file-backed buffers).
- Policy applies to buffer content and name; file-name check is an extra guard, not a symlink follow.

**Smoke test:** `scripts/smoke/buffer-read.el` — temp buffers; test current/named buffer, offset/limit, negative offset, missing buffer, blocked buffer name. Wire into `scripts/eclaw-validate-elisp.sh` as `--smoke buffer-read`.

#### Tool 2: `emacs_context` ✓

**Purpose:** Cheap session orientation before heavier reads.

**Parameters:** none required; optional `max_buffers` integer (default 20, hard cap 100).

**Return format** (plain text, fixed sections):

```text
Emacs VERSION (system-configuration)
Session started: ...   ; eclaw--emacs-started-at or (current-time) fallback

Current buffer:
  name: ...
  file: ... | (none)
  mode: major-mode
  modified: yes/no
  point: N | mark: N | region: lines A-B (or none)

Open buffers (TOTAL, showing N):
  [modified] NAME → FILE or (none)
  ...
```

**Emacs primitives:** `emacs-version`, `system-configuration`, `(current-buffer)`, `buffer-file-name`, `symbol-name` of `major-mode`, `buffer-modified-p`, `point`, `mark`, `(region-active-p)`, `(buffer-list)` sorted by `string-lessp` on name.

**Safety:** Metadata only — no buffer contents. Apply the same buffer-name deny list when listing; omit or redact entries for sensitive buffers.

#### Tool 3: `describe_symbol` ✓

**Purpose:** Programmatic `C-h f` / `C-h v` / `C-h k` for the model.

**Parameters:**

| Param | Type | Required | Notes |
|-------|------|----------|-------|
| `name` | string | yes | Symbol name (with or without leading `:`) |
| `kind` | string | optional | `function`, `variable`, `command`, `key`, or `auto` (default) |

**Return sections** (omit when empty):

- Symbol name and detected kind
- Documentation: `(documentation sym 'function)` / `'variable` / `'property`
- For functions: arglist (`arglist sym 'string` or equivalent); `(interactive-form sym)` when command
- For variables: `custom-type` from `(get sym 'custom-type)` when present
- Source location: `(symbol-file sym 'defun)` / `'defvar` when available
- **Do not return `(symbol-value sym)` in v1** — avoids leaking `eclaw-api-key`, mail addresses, etc.

**`kind` = `key`:** resolve via `kbd` / `key-binding`; document as best-effort.

**Companion: `apropos` ✓**

| Param | Type | Notes |
|-------|------|-------|
| `pattern` | string | regexp for `(apropos-internal pattern)` |
| `max_results` | integer | default 30, cap 100 |

Return symbol names + one-line doc summaries only (no values).

#### Deferred introspection / action tools (do not implement in 1e)

See also [`notes/tool-discussion.txt`](notes/tool-discussion.txt).

| Tool | Why deferred |
|------|--------------|
| `shell_run` | High risk; needs timeout/blocklist |
| `kill_ring_read` / `kill_ring_write` | Editing bridge, not introspection |
| `git_log` / `git_diff` | Valuable but external-process scope |
| LSP tools | Requires eglot/lsp-mode detection |

#### Implementation checklist

1. ✓ Add `eclaw--buffer-sensitive-p` helper + `defcustom` deny regexp list.
2. ✓ Implement `eclaw-tool-buffer-read` + `eclaw-deftool buffer_read`.
3. ✓ Smoke test + byte-compile (`scripts/smoke/buffer-read.el`; `--smoke buffer-read`).
4. ✓ Implement `eclaw-tool-emacs-context` + tool registration.
5. ✓ Implement `eclaw-tool-describe-symbol` + `eclaw-tool-apropos`.
6. ✓ Per-tool guidance in `eclaw-deftool` descriptions (not duplicated in system prompt).
7. ✓ Update **Registered tools** table at top of this file (**Current Features**).
8. ✓ Mark Milestone 1e done; move implemented bullets from this section to **Current Features**.

**Verification:**

```bash
scripts/eclaw-validate-elisp.sh --compile
scripts/eclaw-validate-elisp.sh --require
scripts/eclaw-validate-elisp.sh --smoke buffer-read
scripts/eclaw-validate-elisp.sh --smoke emacs-context
scripts/eclaw-validate-elisp.sh --smoke describe-symbol
```

Interactive: `M-x eclaw-agent-chat` with prompts like “what buffer am I in?” and “describe the symbol `eclaw-deftool`”.

---

## Deferred (not planned near-term)

### Async transport

Replace `url-retrieve-synchronously` with `url-retrieve` and callbacks. **Optional future work** — not required for current single-task usage.

### Streaming

Token streaming and incremental buffer updates. Would need async transport and a small renderer abstraction. **Optional future work.**

---

# Source file layout — split milestone ✓

Split complete (May 2026). **`eclaw.el`** is **~650 lines**; siblings **`eclaw-tools.el`** ~1,080, **`eclaw-skills.el`** ~200, **`eclaw-http.el`** ~200, **`eclaw-web-search.el`** ~250.

## Current layout

```text
eclaw.el            ; Commentary, Configuration, Conversation, request assembly,
                    ; orchestration, logging UI, interactive entrypoints, `provide'
eclaw-skills.el     ; Agent skills cache, discovery, system block (~200 lines; split slice 2 ✓)
eclaw-tools.el      ; `eclaw-deftool', registry, handlers, dispatch (~1,080 lines; split slice 3 ✓)
eclaw-http.el       ; HTTP transport (split slice 1 ✓; ~200 lines)
eclaw-web-search.el ; web search/fetch tools (Jina default; ~250 lines)
```

Names align with **`;;;`** section boundaries in current `eclaw.el`; avoid finer fragmentation until a layer clearly owns a future feature (see “Later modules” below).

## Dependency wrinkles (mandatory slice rules)

1. **`eclaw-build-chat-payload`** (in **`eclaw.el`** after **`;;; Request assembly`**) calls **`eclaw-tool-definitions`**. Pure **`eclaw-http`** must **not** load **`eclaw-tools`**: (**done**) **`eclaw-http.el`** stays free of registry imports; **`eclaw-build-chat-payload`** remains in **`eclaw.el`**

2. **`eclaw-system-message`** pulls **`eclaw--skills-system-block`**. **`eclaw-skills` must load before** that helper is defined — typically `(require 'eclaw-skills)` from `eclaw.el` before the `;;; Conversation` block that defines `eclaw-system-message`, **or** keep `eclaw-system-message` below the split skills file in load order.

3. **`skill_write`** calls **`eclaw--invalidate-skills-cache`** (**`eclaw-tools.el`**; clears **`eclaw--skills-cache`** in **`eclaw-skills.el`**). **`eclaw-tools` requires `eclaw-skills`** (or duplicates are forbidden).

4. **Macros**: keep **`eval-and-compile` helpers before `eclaw-deftool`** inside `eclaw-tools.el`; do not split the macro tail into a third file without strong reason.

5. **Verification** after **each slice**: `byte-compile-file` on touched files + load `eclaw.el` in a clean `emacs -Q` / `emacs -batch`; fix forward references immediately.

## Split slices (do in order; each mergeable alone)

Each slice moves code only (plus `provide`/`require`s and PLAN commentary); behavior and public entrypoints unchanged.

### Split slice 1 — `eclaw-http.el` ✅ **done**

**Moved:** `eclaw--utf8-unibyte-string` through **`eclaw-get-tool-calls`** into **`eclaw-http.el`** (`provide` **`eclaw-http`**). Compiler silencing: **`declare-function`** / **`defvar`** for core symbols; **`eval-when-compile defvar`** for **`url-*`** buffer locals.

**Left in `eclaw.el`:** **`eclaw-build-chat-payload`** after **`(require 'eclaw-tools)`** and **`(require 'eclaw-http)`**. **`(require 'url)`** removed from **`eclaw.el`** (HTTP-only).

**Verify:** `emacs -batch -Q -L <repo> -f batch-byte-compile eclaw-http.el eclaw.el` and `(require 'eclaw)` (see **Handoff** below).

### Split slice 2 — `eclaw-skills.el` ✅ **done**

**Moved:** everything under former `;;; Agent skills` (`eclaw--skills-cache` through **`eclaw--skills-system-block`**) into **`eclaw-skills.el`** (`provide` **`eclaw-skills`**). **`eclaw--invalidate-skills-cache`** moved with **`skill_write`** to **`eclaw-tools.el`** (clears **`eclaw--skills-cache`**).

**`eclaw.el`:** **`(require 'eclaw-skills)`** before **`;;; Conversation`** / **`eclaw-system-message`**.

**Depends:** filesystem; **`declare-function eclaw-debug-message`** from **`eclaw`**.

**Verify:** `emacs -batch -Q -L <repo> -f batch-byte-compile eclaw-skills.el eclaw-http.el eclaw.el` and `(require 'eclaw)`.

### Split slice 3 — `eclaw-tools.el` ✅ **done**

**Moved:** **`;;; Tools` + `;;; Tool execution`** — `eclaw-deftool`, registry, `eclaw-tool-definitions`, all handlers, **`eclaw--dispatch-one-tool-call`**, **`eclaw--tool-result-messages`**, through the end of that section (up to but not including **`;;; Request assembly`**).

**Top of file:** `(require 'eclaw-skills)` and handler deps (`subr-x`, `seq`, `json`).

**`eclaw.el`:** `(require 'eclaw-tools)` before **`eclaw-build-chat-payload`** and **`(require 'eclaw-http)`**.

**Verify:** `emacs -batch -Q -L <repo> -f batch-byte-compile eclaw-skills.el eclaw-tools.el eclaw-http.el eclaw.el` and `(require 'eclaw)`.

### Split slice 4 — Documentation / packaging hygiene ✅ **done**

**Updated:** Commentary header in **`eclaw.el`** (“Layers” + load story); **`docs/http-transport.md`** (multi-file layout, `eclaw-tools` / payload split); **`README.md`** (all `eclaw-*.el` on `load-path`, smoke-test commands); this PLAN (obsolete “monolithic” / “next slice” notes removed).

---

## Later modules (defer until a feature owns them)

```text
eclaw-ui.el
eclaw-logging.el
eclaw-mode.el
eclaw-introspect.el   ; optional split if eclaw-tools.el grows further (Milestone 1e)
```

**AI-assisted editing:** coarse layer files shorten the buffer when changing “one layer” (`eclaw-tools.el` ≈ handlers + approvals); **`eclaw.el`** stays the orchestration spine and is still loaded for multi-layer reasoning.

---

# Historical note

Duplicate `eclaw-build-messages` once dropped conversation history; removed so history is always included in outgoing payloads.

**Tool-call approval:** Slices A–F complete. **Multi-file split:** complete (**`eclaw-http.el`**, **`eclaw-skills.el`**, **`eclaw-tools.el`**, slice 4 docs).

---

# Web UI (local experiment) ✓

Optional browser front-end in **`eclaw-web.el`** + **`web/chat.html`**, using
emacs-web-server on `127.0.0.1` (default port 9876):

- `GET /` — chat page; `POST /api/chat` — JSON in/out, calls `eclaw-chat`
- `GET /api/stats` — token usage JSON (last turn, conversation, Emacs lifetime + start time)
- `GET /api/settings` — per-tool policy, model, prompt limits, push config (`push_enabled`, `push_vapid_public_key`)
- `PATCH /api/settings` (or `POST`) — update tool policy from JSON `{ tools: { ... } }`
- `GET /sw.js` — service worker (no cache)
- `POST /api/push/subscribe` / `DELETE /api/push/subscribe` — store/remove browser push subscriptions
- `POST /api/reset` — `eclaw-reset-conversation`
- `GET /api/conversations` — archived snapshot metadata (newest first)
- `POST /api/conversations/restore` — body `{ "file": "….json" }` → `eclaw-restore-conversation`; returns `{ messages, usage }`
- **Conversation history** panel (clock icon) and **Sync live session** button in **`web/chat.html`** (distinct from archive restore)
- Tool policy panel and **notifications bell** in **`web/chat.html`**
- Token stats bar in the browser: input/output counts for last turn, current chat (since reset), and cumulative since Emacs start; `/api/chat` and `/api/reset` also return `usage` in the JSON body
- `M-x eclaw-web-start` / `eclaw-web-stop` / `eclaw-web-open`
- Shares global `eclaw-conversation` with `*eclaw*`; tool approval `off` in web handler
- Not auto-loaded: `(require 'eclaw-web)` after emacs-web-server is on `load-path`

Limitations: blocking HTTP, no streaming, no per-client sessions (see Milestone 2). Web Push requires VAPID keys, pywebpush, and `eclaw-notify-enabled` (see Milestone 5 above).

---

# Future direction (not fully implemented)

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
- Agent skills are **indexed capabilities** loaded on demand via `read_file`

Further evolution: isolated sessions, richer UI, and eventually a cloud-hosted runtime—without losing inspectability. Async transport and streaming are optional, not current priorities.
