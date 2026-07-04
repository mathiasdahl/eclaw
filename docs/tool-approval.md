# Tool call approval

eclaw gates local tool execution before handlers run (`eclaw-tool-approval-mode` in `eclaw-tools.el`). **Every tool call is gated by default** on a fresh install. Denied or batch-denied calls still produce a normal `role: tool` message so the OpenRouter conversation trace stays valid.

## Policy

| Variable | Values | Default |
|----------|--------|---------|
| `eclaw-tool-approval-mode` | `off`, `writes`, `all` | `all` |
| `eclaw-tool-approval-noninteractive` | `deny`, `allow` | `deny` |

Write tools (`notes_write_text`, `skill_write`, …) are tagged `:write` in the registry. With `writes`, only those tools are gated; with `all`, every registered tool is gated.

## Gate order (`eclaw--dispatch-one-tool-call`)

1. Not gated (`off`, or read tool under `writes`) → run handler.
2. Matching persisted **allow** rule → run handler; transcript notes `saved-rule`.
3. Matching **session** allow rule → run handler; transcript notes `session-rule`.
4. Batch Emacs (`noninteractive`) → `eclaw-tool-approval-noninteractive` (`allow` or `deny`).
5. Interactive minibuffer → allow once, allow for this Emacs session, remember (global or args-scoped), or deny. Each choice has a single-key shortcut (`a`, `s`, `t`, `r`, `e`, `d`; see prompt).

Denial returns `eclaw--tool-call-not-approved-msg` without calling the handler.

## Persisted rules

File: `<eclaw-folder>/tool-approval-rules.el` (Elisp `read` / `prin1` alist). Default folder is `~/.eclaw/`.

Rule keys (broad → narrow):

- `"read_file"` — allow that tool everywhere (legacy Slice D format).
- `("read_file")` — same (normalized).
- `("read_file" nil "{\"path\":\"src\"}")` — allow with canonical JSON args.
- `("read_file" nil "{\"path\":\"src/foo.el\",\"offset\":100,\"limit\":50}")` — allow a specific line-range read.

The middle element of a scoped key is reserved for future use and is always `nil` today. Matching uses wildcards: a stored global rule matches any args; an args-scoped rule matches only that canonical JSON key.

**Commands:** `M-x eclaw-list-tool-approval-rules`, `M-x eclaw-remove-tool-approval-rule`, `M-x eclaw-clear-tool-approval-rules`.

## Session rules

In-memory allow rules for the running Emacs process (`eclaw--tool-approval-session-rules` in `eclaw-tools.el`). Same key shapes and wildcard matching as persisted rules, but **not written to disk** — restarting Emacs clears them.

**Minibuffer “session” options:**

- **session** (`s`) — global tool rule for this Emacs session.
- **session-exact** (`t`) — tool + canonical args (when args are non-empty).

**Minibuffer “remember” options** (persisted to `tool-approval-rules.el`):

- **remember** (`r`) — global tool rule.
- **remember-exact** (`e`) — tool + canonical args (when args are non-empty).

## Multi-tool rounds

The model may return several `tool_calls` in one assistant message. `eclaw--tool-result-messages` maps over the list: each `tool_call_id` gets exactly one tool message. Approvals are per call; one denial does not block siblings in the same round.

## Caps and synthetic results

`eclaw-chat` loops until plain assistant text or a cap fires:

- **`eclaw-max-completions-per-prompt`** — before the next HTTP request, a synthetic assistant message ends the turn. No pending `tool_calls` at that point.
- **`eclaw-max-tokens-per-prompt`** — after a response that includes `tool_calls`, if cumulative `total_tokens` exceeds the ceiling, `eclaw--tool-result-messages` is called with `synth-reason` instead of dispatch. Handlers and the approval gate are **not** run; every pending call gets `[eclaw aborted: …]` content, then the turn stops.

That keeps API history valid without prompting for tools that will not execute.

## Transcript

When buffer `*eclaw*` exists, gated outcomes append `[eclaw: tool approval] ALLOW|DENY` lines (`eclaw--tool-approval-transcript-line`). Echo-area `message` on dispatch is unchanged.
