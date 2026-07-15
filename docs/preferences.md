# User preferences (memory)

eclaw stores short snippets about you in `preferences.md` under `eclaw-folder` (default `~/.eclaw/preferences.md`). The file is injected into every completion request as part of the system message, so preferences survive `eclaw-reset-conversation` and appear at the start of each new chat session.

## What is injected

`eclaw-system-message` builds the system role content as:

1. `eclaw-system-prompt` (static instructions)
2. User preferences block (`eclaw--preferences-system-block`) when the file exists and is non-empty
3. Optional agent skills index (`eclaw--skills-system-block`)
4. Session context block (`eclaw--session-context-block`)

The preferences block looks like:

```text
## User preferences

Short snippets about the user, stored across sessions. Use `preferences_append` to add and `preferences_write` to replace.

- Prefers concise answers
- Timezone: Europe/Stockholm
```

Empty or missing file → no block (zero extra tokens).

## File format

Plain Markdown bullet list — one short snippet per line:

```markdown
- Prefers concise answers
- Timezone: Europe/Stockholm
```

You can edit `preferences.md` directly anytime.

## Size limit

`eclaw-preferences-max-chars` (default **2048**) caps both injection and writes:

- On inject: content beyond the cap is truncated with a one-line `(truncated; N chars omitted)` notice.
- On write/append: requests that would exceed the cap are rejected.

## Tools

| Tool | Risk | Purpose |
|------|------|---------|
| `preferences_append` | `:write` | Add one bullet line (`snippet` argument) |
| `preferences_write` | `:write` | Replace the entire file (`content` argument) |

Both are approval-gated under default `eclaw-tool-approval-mode` (`writes`).

Example: *"Remember that I prefer Swedish for personal chat."* → agent calls `preferences_append` with `snippet: "Prefers Swedish for personal chat"`.

To fix or remove entries, use `preferences_write` with an updated bullet list (or edit the file manually).

## Caching

Preferences are read from disk only when `preferences.md` changes (mtime-based cache, same idea as the skills index). Tool writes call `eclaw--invalidate-preferences-cache` so the next system message rebuild picks up changes immediately.

## Prompt cache

The preferences block is placed **before** the skills index and session date in the system message. It changes only when you or the agent updates the file, keeping the longest stable prefix together for provider prompt-cache hits.
