# Restore older chats — working plan

> **Temporary.** Use this file step-by-step during implementation. When the feature is done, delete this file and keep only a short overview in [`PLAN.md`](../PLAN.md).

## Goal

"New conversation" already archives to Markdown. Add **JSON snapshots** with the full API trace and a **web UI** to list and restore them — in **small steps**, one per context window.

## Progress

Mark steps done here as you go:

- [x] **1a** — Snapshot path helper + format spec (`eclaw.el`)
- [ ] **1b** — `eclaw--conversation-write-snapshot` (not wired yet)
- [ ] **1c** — Wire snapshot into `eclaw-archive-current-conversation`
- [ ] **1d** — Smoke: `conversation-snapshot-write`
- [ ] **2a** — `eclaw--conversation-read-snapshot`
- [ ] **2b** — `eclaw-list-archived-conversations`
- [ ] **2c** — `eclaw-restore-conversation`
- [ ] **2d** — Smoke: `conversation-restore`
- [ ] **3a** — `GET /api/conversations`
- [ ] **3b** — `POST /api/conversations/restore`
- [ ] **4a** — History panel shell (`web/chat.html`)
- [ ] **4b** — Fetch and render list
- [ ] **4c** — Restore action + confirm
- [ ] **4d** — Rename "Load session" button
- [ ] **5** — README + PLAN overview (then delete this file)

## Current gap

- `eclaw-reset-conversation` in [`eclaw.el`](../eclaw.el) archives human-readable `.md` only (no `tool_calls` / tool messages).
- Web "Load session" = sync live Emacs memory (`GET /api/conversation`), not restore from disk.

---

## Step map (do in order)

Each step touches **1–2 files max**. Verify before moving on.

| Step | Size | Files | Depends on |
|------|------|-------|------------|
| **1a** | ~5 min | `eclaw.el` | — |
| **1b** | small | `eclaw.el` | 1a |
| **1c** | tiny | `eclaw.el` | 1b |
| **1d** | small | `scripts/smoke/…`, `scripts/eclaw-validate-elisp.sh` | 1c |
| **2a** | small | `eclaw.el` | 1d |
| **2b** | tiny | `eclaw.el` | 2a |
| **2c** | small | `eclaw.el` | 2a, 2b |
| **2d** | small | `scripts/smoke/…`, validate script | 2c |
| **3a** | tiny | `eclaw-web.el` | 2b |
| **3b** | tiny | `eclaw-web.el` | 2c, 3a |
| **4a** | tiny | `web/chat.html` | — (can parallel after 3a) |
| **4b** | small | `web/chat.html` | 3a, 4a |
| **4c** | small | `web/chat.html` | 3b, 4b |
| **4d** | tiny | `web/chat.html` | 4c |
| **5** | tiny | `README.md`, `PLAN.md` | 4d |

---

## How to start a session

Attach or `@`-reference this file, then use the step prompt, e.g.:

> Execute Step 1a from `docs/plan-restore-older-chats.md`

## Handoff after each step

When a step is **finished** (done-when criteria met, progress checkbox ticked):

1. Mark the step done in the **Progress** checklist above.
2. End your reply with a single handoff line for the **next** step (or nothing after Step 5):

```
Execute Step 1b from docs/plan-restore-older-chats.md
```

Use the exact step id and path — no extra wording. After the final step (5), omit the handoff line.

---

## Step details

### Step 1a — Snapshot path + format spec

**Scope:** Add `eclaw--conversation-snapshot-path` (mirror `eclaw--conversation-archive-path` but `.json`). Add a comment block documenting snapshot schema v1. No behavior change yet.

**Done when:** `--compile` + `--parens` on `eclaw.el` pass.

**Prompt:**
> Execute Step 1a from `docs/plan-restore-older-chats.md`: add snapshot path helper and format spec comment in eclaw.el only.

---

### Step 1b — Write snapshot function

**Scope:** Add `eclaw--conversation-write-snapshot` that writes JSON with: `version`, `id`, `started`, `ended`, `model`, `folder`, `usage`, `messages` (full `eclaw-conversation`). Use temp file + rename. **Do not** wire into archive yet.

**Done when:** Can call the function manually in batch and get valid JSON. `--compile` + `--parens` pass.

**Prompt:**
> Execute Step 1b from `docs/plan-restore-older-chats.md`: implement eclaw--conversation-write-snapshot in eclaw.el (write only, not wired).

---

### Step 1c — Wire into archive

**Scope:** In `eclaw-archive-current-conversation`, after writing `.md`, call write-snapshot for the matching `.json`. If JSON write fails, treat as archive failure (same as reset safety).

**Done when:** `M-x eclaw-reset-conversation` (or existing archive smoke) produces both `.md` and `.json`.

**Prompt:**
> Execute Step 1c from `docs/plan-restore-older-chats.md`: wire JSON snapshot write into eclaw-archive-current-conversation.

---

### Step 1d — Smoke test: snapshot write

**Scope:** New `scripts/smoke/conversation-snapshot-write.el`: set `eclaw-folder` to temp dir, populate `eclaw-conversation` with user + assistant + tool messages (minimal fixture), archive, assert `.json` exists and `messages` round-trip via `json-read`. Wire `--smoke conversation-snapshot-write` in validate script.

**Done when:** `scripts/eclaw-validate-elisp.sh --smoke conversation-snapshot-write` passes.

**Prompt:**
> Execute Step 1d from `docs/plan-restore-older-chats.md`: add conversation-snapshot-write smoke test.

---

### Step 2a — Read snapshot

**Scope:** Add `eclaw--conversation-read-snapshot` (file path → validated alist). Check `version == 1`, required keys, `messages` is a list. Return error on bad/missing file.

**Done when:** Smoke from 1d can read back the written file. `--compile` + `--parens` pass.

**Prompt:**
> Execute Step 2a from `docs/plan-restore-older-chats.md`: implement eclaw--conversation-read-snapshot in eclaw.el.

---

### Step 2b — List metadata

**Scope:** Add `eclaw-list-archived-conversations` returning newest-first plists: `file`, `started`, `ended`, `turns`, `preview` (first user message), `restorable` (t when `.json` parses). Scan `conversations/*.json`; ignore broken files with a debug message.

**Done when:** Returns correct rows for temp archives. No side effects.

**Prompt:**
> Execute Step 2b from `docs/plan-restore-older-chats.md`: implement eclaw-list-archived-conversations in eclaw.el.

---

### Step 2c — Restore into live session

**Scope:** Add `eclaw-restore-conversation` (interactive + programmatic). Args: snapshot file basename.

1. If current session has content → archive first (reuse existing archive); abort on failure.
2. Load snapshot → set `eclaw-conversation`, `eclaw--session-started`, `eclaw--usage-conversation`.
3. Optionally rebuild `*eclaw*` display buffer from display messages (keep minimal).

Validate basename (no `/`, no `..`).

**Done when:** Manual batch test: archive → reset → restore → `eclaw-conversation` matches original.

**Prompt:**
> Execute Step 2c from `docs/plan-restore-older-chats.md`: implement eclaw-restore-conversation in eclaw.el.

---

### Step 2d — Smoke test: full roundtrip

**Scope:** `scripts/smoke/conversation-restore.el`: build conversation with tool round, archive, reset (empty), restore, assert message list + `eclaw--session-started` equal. Wire `--smoke conversation-restore`.

**Done when:** `--smoke conversation-restore` passes.

**Prompt:**
> Execute Step 2d from `docs/plan-restore-older-chats.md`: add conversation-restore smoke test.

---

### Step 3a — GET /api/conversations

**Scope:** `eclaw-web.el` only. Handler calls `eclaw-list-archived-conversations`, returns JSON array. Route in existing dispatcher.

**Done when:** `curl localhost:9876/.../api/conversations` returns list after a reset. `--compile` + `--parens` on `eclaw-web.el`.

**Prompt:**
> Execute Step 3a from `docs/plan-restore-older-chats.md`: add GET /api/conversations in eclaw-web.el.

---

### Step 3b — POST /api/conversations/restore

**Scope:** `eclaw-web.el` only. Body `{ "file": "….json" }` → `eclaw-restore-conversation` → response `{ messages, usage }` (reuse `eclaw-conversation-display-messages` + `eclaw-usage-stats`).

**Done when:** curl restore returns messages and next `POST /api/chat` sees full history.

**Prompt:**
> Execute Step 3b from `docs/plan-restore-older-chats.md`: add POST /api/conversations/restore in eclaw-web.el.

---

### Step 4a — Panel shell

**Scope:** `web/chat.html` only. History toolbar icon + hidden panel/modal (HTML + CSS). Toggle open/close. **No fetch yet.**

**Done when:** Button opens/closes empty panel in browser.

**Prompt:**
> Execute Step 4a from `docs/plan-restore-older-chats.md`: add history panel shell to web/chat.html (no API calls yet).

---

### Step 4b — Render list

**Scope:** On panel open, `GET /api/conversations`, render rows (timestamp, preview, turns). Loading + empty states. No restore click yet.

**Done when:** List shows archives after reset in browser.

**Prompt:**
> Execute Step 4b from `docs/plan-restore-older-chats.md`: fetch and render conversation list in web/chat.html history panel.

---

### Step 4c — Restore action

**Scope:** Row click → if current chat non-empty, `confirm()` → `POST /api/conversations/restore` → clear `#messages` and render returned messages (reuse `loadSession` pattern). Close panel. Respect `busy` flag.

**Done when:** Full browser flow: chat → reset → open history → restore → continue chatting.

**Prompt:**
> Execute Step 4c from `docs/plan-restore-older-chats.md`: add restore action with confirm in web/chat.html.

---

### Step 4d — Label cleanup

**Scope:** Rename "Load session" button title/aria-label to something like "Sync live session" so it is distinct from archive restore.

**Done when:** Tooltips/labels are unambiguous.

**Prompt:**
> Execute Step 4d from `docs/plan-restore-older-chats.md`: rename Load session button labels in web/chat.html.

---

### Step 5 — Docs + cleanup

**Scope:** `README.md` (user-facing: new conversation archives JSON; history button restores). `PLAN.md` (short overview of restore feature; Emacs UI deferred). **Delete this file** (`docs/plan-restore-older-chats.md`).

**Done when:** Docs match implemented behavior. This working plan file is removed.

**Prompt:**
> Execute Step 5 from `docs/plan-restore-older-chats.md`: update README.md and PLAN.md, then delete docs/plan-restore-older-chats.md.

---

## Snapshot format (reference)

```json
{
  "version": 1,
  "id": "2026-07-21T22:15:30+0200",
  "started": "2026-07-21T21:00:00+0200",
  "ended": "2026-07-21T22:15:30+0200",
  "model": "deepseek/...",
  "folder": "/home/user/.eclaw",
  "usage": { "prompt_tokens": 1234, "completion_tokens": 567 },
  "messages": [ /* full eclaw-conversation alists */ ]
}
```

## Out of scope

- Emacs `M-x` restore UI
- Parallel sessions (Milestone 2)
- Restoring legacy Markdown-only archives
- Per-client / streaming changes

## Verification cheat sheet

After any Elisp step:

```bash
scripts/eclaw-validate-elisp.sh --parens eclaw.el
scripts/eclaw-validate-elisp.sh --compile
scripts/eclaw-validate-elisp.sh --require
```

After smoke steps, also run the new `--smoke …` target.

After web steps, manual check in browser is enough.
