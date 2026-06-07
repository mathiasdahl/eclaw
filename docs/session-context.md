# Session context (date and time)

eclaw injects the **session start** date and time into every completion request as part of the system message. The model uses this for time-sensitive work—especially `web_search` query formulation—instead of guessing from its training cutoff.

## What is injected

`eclaw-system-message` builds the system role content as:

1. `eclaw-system-prompt` (static instructions)
2. Optional project skills index (`eclaw--skills-system-block`)
3. Session context block (`eclaw--session-context-block`)

The session block looks like:

```text
Session context: started Sunday, 2026-06-07 14:32:05 CEST.
Use this date for time-sensitive queries and web search, not your training cutoff.
```

The timestamp uses Emacs local time (`format-time-string` with `%Z` for the timezone abbreviation).

## When it is set and cleared

- **Set:** on the first `eclaw-chat` turn via `eclaw--ensure-session-started`, which records `eclaw--session-started` and `eclaw--session-project` (absolute `default-directory` at session start).
- **Frozen:** the same formatted string is reused for every completion round and user turn until the session ends. It does **not** refresh on each HTTP request.
- **Cleared:** `eclaw-reset-conversation` sets `eclaw--session-started` to `nil`; the next chat turn starts a new session with a new timestamp.

The archive YAML frontmatter `started:` field uses the same `eclaw--session-started` value.

## Why once per session

Refreshing the clock on every completion would change the system message on every tool-loop round, reducing provider prompt-cache hits on the stable prefix. Session-start time is enough for correct year/month in web search and most “current events” queries.

Tradeoff: if a session stays open past midnight, the injected date remains the session start date until reset. That is rare compared to the common failure mode (wrong year from training bias).

## No datetime tool

There is no `get_datetime` tool. The injected block is the canonical source of “now” for the assistant. A separate tool may be added later if live clock queries mid-session become important.
