# Validation handoff: runtime eval + web tool policy

Use this file after clearing context. Resume by running the checks below and fixing anything that fails.

## What was implemented

### Core (tool policy + eval)
- **[eclaw-tools.el](../eclaw-tools.el)**
  - Persisted per-tool enable matrix: `<eclaw-folder>/tool-policy.el`
  - API: `eclaw-tool-policy-enabled-p`, `eclaw-tool-policy-set`, `eclaw-tool-policy-apply-updates`, `eclaw-tool-policy-list`
  - Commands: `eclaw-list-tool-policy`, `eclaw-set-tool-policy`
  - `:dangerous` risk class; `:write` approval mode also gates `:dangerous`
  - `eclaw-tool-definitions` and `eclaw--dispatch-one-tool-call` filter by policy
  - Default: all tools enabled except `eval_elisp` (off); `web_search`/`web_fetch`/`send_email` seeded from module `defcustom`s when no file exists
- **[eclaw-eval.el](../eclaw-eval.el)** (new)
  - `eval_elisp` tool (`:dangerous`), full `(eval form t)`, timeout + code length cap
- **[eclaw.el](../eclaw.el)** — `(require 'eclaw-eval)`

### Module registration
- **[eclaw-web-search.el](../eclaw-web-search.el)** — always registers `web_search` / `web_fetch` (policy controls runtime)
- **[eclaw-mail.el](../eclaw-mail.el)** — always registers `send_email`

### Web
- **[eclaw-web.el](../eclaw-web.el)** — `GET /api/settings`, `PATCH /api/settings`, `POST /api/settings` (alias)
- **[web/chat.html](../web/chat.html)** — Settings panel, per-tool checkboxes by risk, confirm for dangerous tools

### Docs / tests
- **[docs/tool-policy.md](tool-policy.md)** (new)
- **[docs/tool-approval.md](tool-approval.md)** — `:dangerous` note
- **[PLAN.md](../PLAN.md)** — updated
- **[scripts/smoke/eval-elisp.el](../scripts/smoke/eval-elisp.el)** (new)
- **[scripts/smoke/load.el](../scripts/smoke/load.el)**, **[scripts/smoke/web-search.el](../scripts/smoke/web-search.el)**, **[scripts/smoke/send-email.el](../scripts/smoke/send-email.el)** — updated for always-registered tools + policy
- **[scripts/eclaw-validate-elisp.sh](../scripts/eclaw-validate-elisp.sh)** — `--smoke eval-elisp` wired

## Paren / load fixes already done (session)

Several edits left **unbalanced parentheses**; these were fixed iteratively with `check-parens` / `parse-partial-sexp`:

| File | Status at end of session |
|------|---------------------------|
| `eclaw-tools.el` | `check-parens: OK` |
| `eclaw-web.el` | `check-parens: OK` |
| `eclaw-eval.el` | `check-parens: OK` |

**Dispatch function** in `eclaw-tools.el` was rewritten (clean `let*` binding `result` inside `cond` `t` branch) after botched paren edits.

**Likely cause of long hangs during verification:** many concurrent `emacs -batch` processes. After `pkill -f "emacs -batch"`, isolated loads succeeded quickly:

```bash
emacs -batch -Q -L /home/mathias/prj/eclaw -l eclaw-skills.el --eval "(princ \"skills-ok\n\")"
emacs -batch -Q -L /home/mathias/prj/eclaw -l eclaw-tools.el --eval "(princ \"tools-ok\n\")"
```

**Stale `.elc` trap:** if `.el` is newer than `.elc`, Emacs may load **older bytecode** and skip `eclaw-eval` / new policy code. Either delete stale `.elc` for changed files or recompile before smoke tests.

## Validation checklist (run in order)

Run from repo root: `/home/mathias/prj/eclaw`

### 0. Clean environment (recommended first)

```bash
pkill -f "emacs -batch" 2>/dev/null || true
cd /home/mathias/prj/eclaw
rm -f eclaw.elc eclaw-tools.elc eclaw-eval.elc eclaw-web.elc eclaw-web-search.elc eclaw-mail.elc
```

### 1. Paren check (elisp-editing skill)

```bash
ELISP_EDIT_SKILL_SCRIPTS=${ELISP_EDIT_SKILL_SCRIPTS:-$HOME/.cursor/skills/elisp-editing/scripts}
for f in eclaw-tools.el eclaw-eval.el eclaw-web.el; do
  "$ELISP_EDIT_SKILL_SCRIPTS/validate-elisp.sh" --parens "$f"
done
```

Expected: `check-parens: OK` for all three.

### 2. Byte-compile

```bash
scripts/eclaw-validate-elisp.sh --compile
```

Expected: exit 0, fresh `.elc` for changed modules.

### 3. Require chain

```bash
scripts/eclaw-validate-elisp.sh --require
```

Expected: exit 0; `(featurep 'eclaw-eval)` true when evaluated inside that script’s Emacs run.

### 4. Smoke tests

```bash
scripts/eclaw-validate-elisp.sh --smoke load
scripts/eclaw-validate-elisp.sh --smoke eval-elisp
scripts/eclaw-validate-elisp.sh --smoke web-search
scripts/eclaw-validate-elisp.sh --smoke send-email
```

**eval-elisp smoke** (`scripts/smoke/eval-elisp.el`) checks:
- `eval_elisp` registered, tagged `:dangerous`
- disabled by default (not in `eclaw-tool-definitions`)
- enabled after `eclaw-tool-policy-set "eval_elisp" t`
- `(+ 1 2)` → `result=3`
- disabled dispatch returns `eclaw--tool-policy-disabled-msg`

**load smoke** checks all tools registered including `eval_elisp`, and `eval_elisp` disabled by default in policy.

### 5. Manual web UI (optional but valuable)

1. `(require 'eclaw-web)` then `M-x eclaw-web-start` / `eclaw-web-open`
2. Open **Settings** — all tools listed, `eval_elisp` off by default
3. Enable `eval_elisp` (confirm dialog) → Save → `GET /api/settings` shows enabled
4. Disable e.g. `send_email` → Save → tool absent from next chat’s tool list
5. With approval `'all` in `*eclaw*`, enabled `eval_elisp` should still prompt interactively (web chat forces approval `off` but policy still gates)

### 6. API spot-check (curl)

```bash
curl -s http://127.0.0.1:9876/api/settings | head
curl -s -X PATCH http://127.0.0.1:9876/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"tools":{"eval_elisp":true}}' | head
```

(Web server must be running via `eclaw-web-start`.)

## What was NOT verified to completion

- Full `scripts/eclaw-validate-elisp.sh --compile && --require && all smokes` in one shot — interrupted / hung when many Emacs processes were stacked
- `--smoke eval-elisp` after final paren fixes — should pass once compile/require succeed
- Manual web UI and curl API tests — not run end-to-end
- No git commit was made (user did not request)

## If something fails

| Symptom | Likely fix |
|---------|------------|
| `smoke eval-elisp FAIL: eclaw-eval feature loaded` | Stale `eclaw.elc` without `(require 'eclaw-eval)` — remove `.elc` or recompile `eclaw.el` |
| `End of file during parsing` / `check-parens` fail | Re-run paren validation on `eclaw-tools.el` / `eclaw-web.el`; dispatch and `eclaw-web--handle-patch-settings` were trouble spots |
| Emacs batch hangs >30s | `pkill -f "emacs -batch"` then retry one command at a time |
| Web PATCH 404 | Ensure `eclaw-web--handle-request` routes `PATCH` and `POST` for `/api/settings` |

## Related docs

- [docs/tool-policy.md](tool-policy.md) — file format, defaults, web API
- [docs/tool-approval.md](tool-approval.md) — `:dangerous` + approval interaction
- Plan file (do not edit): `.cursor/plans/` — original implementation plan

## Suggested prompt for next session

> Read `docs/validation-handoff-runtime-eval-tool-policy.md` and complete all validation steps. Fix any failures with minimal diffs. Report results; do not commit unless asked.
