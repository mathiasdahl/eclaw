# eval_elisp security

The `eval_elisp` tool runs Elisp in your **running Emacs session** via `(eval form t)`. It is **not a sandbox**. Treat it with the same trust level as `M-:` (`eval-expression`) or evaluating a buffer you did not write yourself.

See also: [tool policy](tool-policy.md), [tool approval](tool-approval.md).

## Purpose

`eval_elisp` exists so a model can customize Emacs at runtime: define helpers, set variables, `require` features, and modify buffers. Dedicated tools (`read_file`, `grep_files`, `notes_write_text`, …) are safer for IO and should be preferred when they suffice.

## Existing gates (administrative layer)

These controls are always active regardless of `eclaw-eval-safety-mode`:

| Control | Mechanism |
|---------|-----------|
| Opt-in | Disabled by default in `tool-policy.el`; omitted from API tool list until enabled |
| Risk class | Tagged `:dangerous`; gated under `eclaw-tool-approval-mode` `writes` and `all` |
| Timeout | `eclaw-eval-timeout-seconds` (default 30) |
| Code size | `eclaw-eval-max-code-length` (32768 bytes) |
| Single form | Only the first sexp from `read-from-string` is evaluated; use `(progn …)` for multiple forms |
| Trailing input | Non-whitespace after the first form is rejected |
| Web exposure | HTTP server binds to localhost; web chat runs with approval `off`, so policy is the main gate there |

## Safety modes (`eclaw-eval-safety-mode`)

Optional content guards (defcustom in `eclaw-eval.el`). Default: **`full`** (same power as unconstrained `(eval form t)` once policy and approval allow the call).

| Mode | Behavior |
|------|----------|
| `full` | No content guards (current legacy behavior) |
| `restricted` | Static denylist on parsed forms **plus** runtime stubs on high-impact functions; still allows `defun`, `setq`, `require`, buffer operations |
| `strict` | Emacs `unsafep` preflight; compute-oriented only (no `defun`, global `setq`, `funcall`, most buffer/file side effects) |

### Restricted mode blocks (summary)

**Tier 1 (static analysis + runtime stubs where noted):** `shell-command`, `async-shell-command`, `call-process`, `start-process`, `make-process`, `open-network-stream`, `delete-file`, `delete-directory`, `kill-emacs`, `byte-compile`, plus `load` and `eval` (static only — not stubbed, so `require` and `defun` keep working)

**Tier 2 (static only — indirection):** `funcall`, `apply`, `intern`, `symbol-function`, `fset`, `defalias`, `advice-add`, `advice-remove`, `put`

Also rejects unquoted Tier-1 symbols passed as the function argument to `apply` / `funcall`.

## Non-guarantees

Even in `restricted` or `strict` mode, a motivated caller with `eval_elisp` enabled may still:

- Redefine eclaw (`defun eclaw-tool-eval-elisp …`, `advice-add`, …) in **`full`** mode, or after bypassing guards
- Invoke **function values** that bypass symbol stubs, e.g. `(apply delete-file '("/path"))` in **`full`** mode (Tier-2 blocks this in **`restricted`**)
- Use **session state** poisoned by an earlier eval or other Emacs code
- Trick the user into approving malicious code in the interactive approval dialog

Guards are **defense-in-depth** against obvious prompt-injection payloads, not a security boundary.

## Safe usage checklist

1. Leave `eval_elisp` **disabled** in tool policy unless you need it.
2. Use `eclaw-tool-approval-mode` **`all`** in `*eclaw*` so every call prompts; read the code before allowing.
3. On the web UI, only enable dangerous tools on **trusted localhost** sessions; prefer keeping `eval_elisp` off there.
4. Set `eclaw-eval-safety-mode` to **`restricted`** when you want customization without shell/network/delete/load/eval.
5. Prefer dedicated read/write tools over eval for file and network access.
6. Disable `eval_elisp` again when the task is done.

## Attack coverage (honest matrix)

| Pattern | Policy / approval | Restricted | Strict (`unsafep`) |
|---------|-------------------|------------|---------------------|
| `(shell-command "…")` | if disabled / denied | blocked | blocked |
| `(defun x () (shell-command "…"))` | if disabled / denied | blocked (stub) | blocked |
| `(apply delete-file '("/x"))` | if disabled / denied | blocked | blocked |
| `(fset 'eclaw-tool-eval-elisp …)` | if disabled / denied | blocked | blocked |
| Pre-poisoned variable holding a dangerous function | no | no | no |
| Redefine eclaw after eval returns | no | no | no |

## Configuration reference

```elisp
;; Defaults
(customize-set-variable 'eclaw-eval-safety-mode 'full)
(customize-set-variable 'eclaw-eval-timeout-seconds 30)
```

Commands: `M-x eclaw-list-tool-policy`, `M-x eclaw-set-tool-policy`, `M-x customize-group RET eclaw-eval RET`.
