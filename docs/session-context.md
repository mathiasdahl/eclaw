# Session context (date and time)

eclaw injects the **session-start date** (no time of day) into every completion request as part of the system message. The model uses this for time-sensitive work—especially `web_search` query formulation—instead of guessing from its training cutoff.

Wall-clock time is available on demand via the `get_datetime` tool.

## What is injected

`eclaw-system-message` builds the system role content as:

1. `eclaw-system-prompt` (static instructions)
2. Optional user preferences block (`eclaw--preferences-system-block`)
3. Optional agent skills index (`eclaw--skills-system-block`)
4. Session context block (`eclaw--session-context-block`)

The session block looks like:

```text
Session context: today is Sunday, 2026-06-07 CEST.
Use this date for time-sensitive queries and web search, not your training cutoff.
Call get_datetime when you need the current time of day.
```

The date uses Emacs local time (`format-time-string` with `%Z` for the timezone abbreviation). Hours, minutes, and seconds are omitted so new sessions on the same calendar day share an identical system-message prefix (better provider prompt-cache hits).

## When it is set and cleared

- **Set:** on the first `eclaw-chat` turn via `eclaw--ensure-session-started`, which records `eclaw--session-started` (full timestamp, used internally).
- **Frozen:** the same formatted date string is reused for every completion round and user turn until the session ends. It does **not** refresh on each HTTP request.
- **Cleared:** `eclaw-reset-conversation` sets `eclaw--session-started` to `nil`; the next chat turn starts a new session with a new date (and internal timestamp).

The archive YAML frontmatter `started:` field uses the full `eclaw--session-started` value. The `folder:` field records `eclaw-folder` at archive time.

## Why date-only in the system message

Refreshing the clock on every completion would change the system message on every tool-loop round, reducing provider prompt-cache hits on the stable prefix.

Including time-of-day in the session block would change the prefix on every new session, even when two sessions start on the same calendar day. Date-only injection invalidates the cache at most once per day (when the calendar date changes).

Tradeoff: if a session stays open past midnight, the injected date remains the session-start date until reset. Call `get_datetime` when live date or time is required mid-session.

## `get_datetime` tool

`:read` risk; enabled by default. Returns the current wall-clock time and the ISO `session_started` timestamp. Use when the user asks for the time of day or when hour/minute precision matters.
