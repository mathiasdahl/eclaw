# Tool policy

eclaw controls which registered tools are **advertised to the model** and **allowed to run** via a persisted per-tool enable matrix. This is separate from the interactive approval gate (`eclaw-tool-approval-mode`).

## File

Path: `<eclaw-folder>/tool-policy.el` (default `~/.eclaw/tool-policy.el`).

Format: Elisp alist read with `read` / written with `prin1`:

```elisp
(("read_file" . t) ("eval_elisp" . nil) ...)
```

When the file is missing, defaults apply (see below). The file is created on the first policy update (web settings save, `M-x eclaw-set-tool-policy`, etc.).

## Defaults

| Tool | Default enabled |
|------|-----------------|
| All registered tools | `t` |
| `eval_elisp` | `nil` |
| `web_search`, `web_fetch` | `eclaw-web-search-enabled` |
| `send_email` | `eclaw-mail-enabled` |
| `send_push` | `eclaw-notify-send-enabled` |

Module `defcustom`s (`eclaw-web-search-enabled`, `eclaw-mail-enabled`, `eclaw-notify-send-enabled`) seed defaults only. Runtime control is the policy file / web UI.

## Enforcement

1. **`eclaw-tool-definitions`** — disabled tools are omitted from the OpenRouter `tools` array.
2. **`eclaw--dispatch-one-tool-call`** — if the model still calls a disabled tool, the handler is not run; the model receives `eclaw--tool-policy-disabled-msg`.

## Risk classes

Registry `:risk` values:

| Risk | Examples | Approval under `writes` mode |
|------|----------|------------------------------|
| `:read` | `read_file`, `web_search` | Not gated |
| `:write` | `notes_write_text`, `preferences_append`, `send_email`, `send_push` | Gated |
| `:dangerous` | `eval_elisp` | Gated (same as `:write`) |

Under `all` mode, every tool is gated. Under `off`, nothing is gated by approval (policy still applies).

## Emacs commands

- `M-x eclaw-list-tool-policy` — list effective policy in `*eclaw tool policy*`
- `M-x eclaw-set-tool-policy` — enable or disable one tool interactively

## Web API

Bind to localhost only (`eclaw-web-host`, default `127.0.0.1`). Enabling dangerous tools from the web is an explicit opt-in; web chat runs with `eclaw-tool-approval-mode` `off`, so policy is the main gate there.

| Method | Path | Body | Response |
|--------|------|------|----------|
| `GET` | `/api/settings` | — | `{ tools: [{ name, description, risk, enabled }], policy_file, models, model }` |
| `PATCH` | `/api/settings` | `{ tools: { "eval_elisp": true, ... } }` or `{ model: "deepseek/deepseek-v4-pro" }` or both | same as GET |
| `POST` | `/api/settings` | same as PATCH | alias for clients without PATCH |

`models` is the list from `eclaw-available-models` (Customize). `model` is the current OpenRouter model id (`eclaw-model`), normalized to an entry in that list when the configured value is not offered.

The web UI sends the full `tools` map on save (all checkboxes), not just changed rows. The model toolbar dropdown saves immediately with `{ model: "..." }` only.

## `eval_elisp`

Full Elisp evaluation in the running Emacs session (`eval form t`). Disabled by default. Limits: `eclaw-eval-timeout-seconds` (default 30), `eclaw-eval-max-code-length` (32768 bytes). Use `(progn ...)` for multiple forms.

Optional content guards: `eclaw-eval-safety-mode` (`full` default, `restricted`, `strict`). See [eval_elisp security](eval-elisp-security.md).

When enabled, the model can redefine functions, set variables, `require` files, and modify eclaw at runtime. Only enable on trusted localhost sessions.

**Security:** not a sandbox. See [eval_elisp security](eval-elisp-security.md) for the trust model, safety modes, and safe usage checklist.
