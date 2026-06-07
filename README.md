# eclaw

Eclaw - An AI agent for Emacs

## This is an experiment

This is an experiment, very much created for my own learning. That
said, I can see how it will quickly start to be useful, just after a
few hours of working with AI to create this project.

## Loading from this repository

Clone the repo and add its directory to `load-path`. All sibling
`eclaw-*.el` files (`eclaw.el`, `eclaw-skills.el`, `eclaw-tools.el`,
`eclaw-http.el`, `eclaw-web-search.el`) must live in that directory; only the core feature
needs to be required:

```emacs-lisp
(add-to-list 'load-path "/path/to/eclaw")
(require 'eclaw)
```

`(require 'eclaw)` pulls in skills, tools, HTTP transport, and web search in order.
After a successful load, `(featurep 'eclaw-http)` and `(featurep 'eclaw-web-search)`
should be non-nil.

Set `JINA_API_KEY` for Jina web tools (free key at https://jina.ai/?sui=apikey).
`web_search` requires it; `web_fetch` works without a key but benefits from one
for higher rate limits.

Tool approval is **on by default** (`eclaw-tool-approval-mode` is `all`): every
local tool call prompts in the minibuffer until you allow it once, for the
session, or via a saved rule. See [`docs/tool-approval.md`](docs/tool-approval.md).
List or edit saved rules with `M-x eclaw-list-tool-approval-rules` and related
commands. Set `eclaw-tool-approval-mode` to `writes` or `off` to relax gating.

Each chat session injects the **session-start date and time** into the system
message so the model can answer time-sensitive questions and web searches with
the correct year. The value is frozen until `M-x eclaw-reset-conversation`.
See [`docs/session-context.md`](docs/session-context.md).

Smoke-test (optional):

```bash
emacs -batch -Q -L /path/to/eclaw -f batch-byte-compile \
  eclaw-skills.el eclaw-tools.el eclaw-http.el eclaw-web-search.el eclaw.el
emacs -batch -Q -L /path/to/eclaw --eval "(require 'eclaw)"
```

Project validation wrapper (uses the personal `elisp-editing` skill scripts):

```bash
scripts/eclaw-validate-elisp.sh --all eclaw-tools.el
scripts/eclaw-validate-elisp.sh --smoke read-file
scripts/eclaw-validate-elisp.sh --smoke load
scripts/eclaw-validate-elisp.sh --smoke web-search
scripts/eclaw-validate-elisp.sh --smoke session-context
```

Structural Elisp edits use `~/.cursor/skills/elisp-editing/scripts/elisp-edit.sh`
(see that skill's `SKILL.md`).

## Web UI (local experiment)

Optional browser chat on the same machine as Emacs, via
[emacs-web-server](https://github.com/eschulte/emacs-web-server). Add both repos to
`load-path`, then:

```emacs-lisp
(add-to-list 'load-path "/path/to/emacs-web-server")
(add-to-list 'load-path "/path/to/eclaw")
(require 'eclaw)
(require 'eclaw-web)
```

- `M-x eclaw-web-start` — serves `http://127.0.0.1:9876/` (host and port are
  customizable; default binds **localhost only**)
- `M-x eclaw-web-open` — open the chat page in your browser
- `M-x eclaw-web-stop` — stop the server

The web UI calls the same `eclaw-chat` orchestration as `M-x eclaw-agent-chat` and
shares global `eclaw-conversation` with the `*eclaw*` buffer.

**Security:** do not forward this port or bind to a public interface. While handling
web requests, `eclaw-tool-approval-mode` is forced to `off`, so local tools run
without minibuffer prompts—acceptable only on a trusted localhost setup.
