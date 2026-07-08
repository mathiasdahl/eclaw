# Emacs Lisp validation

How to verify eclaw Elisp sources after edits.

## Prerequisites

- GNU Emacs on `PATH` (batch mode: `emacs -batch -Q`)
- Personal **elisp-editing** skill scripts at
  `~/.cursor/skills/elisp-editing/scripts/`, or set `ELISP_EDIT_SKILL_SCRIPTS`
  to another install path

The wrapper [`scripts/eclaw-validate-elisp.sh`](../scripts/eclaw-validate-elisp.sh)
delegates paren checks, byte-compile, and require to the skill’s
`validate-elisp.sh`.

## Quick check

From the repo root:

```bash
scripts/eclaw-validate-elisp.sh --compile
scripts/eclaw-validate-elisp.sh --require
scripts/eclaw-validate-elisp.sh --smoke load
```

After touching a specific area, run the matching smoke (see table below).

## Standard workflow

Run steps in order. Prefer **one command at a time** — stacking many concurrent
`emacs -batch` processes can hang or slow validation badly.

### 1. Clean environment (when bytecode or batch runs act stale)

```bash
pkill -f "emacs -batch" 2>/dev/null || true
cd /path/to/eclaw
rm -f *.elc
```

`.elc` files are gitignored. If `.el` is newer than `.elc`, Emacs may load
**older bytecode** and miss recent `require`s or tool registrations. Delete
stale `.elc` or recompile before smoke tests.

### 2. Paren check

On changed `.el` files:

```bash
ELISP_EDIT_SKILL_SCRIPTS=${ELISP_EDIT_SKILL_SCRIPTS:-$HOME/.cursor/skills/elisp-editing/scripts}
"$ELISP_EDIT_SKILL_SCRIPTS/elisp-edit.sh" --check-parens --file /path/to/eclaw/eclaw-tools.el
```

Or via the project wrapper:

```bash
scripts/eclaw-validate-elisp.sh --parens eclaw-tools.el
```

Expected: `check-parens: OK`.

**Tip:** Prefer `elisp-edit.sh --check-parens --file` with **absolute paths**.
Plain `emacs -batch` + `find-file-noselect` has hung in some environments;
`elisp-edit` reads file contents into a temp buffer instead.

### 3. Byte-compile

```bash
scripts/eclaw-validate-elisp.sh --compile
```

Compile order (dependency-safe):

`eclaw-skills.el` → `eclaw-tools.el` → `eclaw-http.el` → `eclaw-web-search.el`
→ `eclaw-mail.el` → `eclaw-eval.el` → `eclaw.el`

(`eclaw-web.el` is optional — not loaded by `(require 'eclaw)`.)

If compiling all modules in one `batch-byte-compile` invocation hangs, compile
each file individually:

```bash
REPO=/path/to/eclaw
for f in eclaw-skills.el eclaw-tools.el eclaw-http.el eclaw-web-search.el \
         eclaw-mail.el eclaw-eval.el eclaw.el; do
  emacs -batch -Q -L "$REPO" -f batch-byte-compile "$REPO/$f"
done
```

Docstring and `let*` warnings in `eclaw-tools.el` during compile are
pre-existing noise, not failures.

### 4. Require chain

```bash
scripts/eclaw-validate-elisp.sh --require
```

Equivalent:

```bash
emacs -batch -Q -L /path/to/eclaw --eval "(require 'eclaw)"
```

Confirms the full `require` graph loads (including `eclaw-eval`, `eclaw-mail`,
`eclaw-web-search`, etc.).

### 5. Smoke tests

```bash
scripts/eclaw-validate-elisp.sh --smoke NAME
```

| Smoke | What it checks |
|-------|----------------|
| `load` | All core features and tools register; `eval_elisp` disabled by default |
| `read-file` | Line ranges, caps, sensitive-path policy |
| `buffer-read` | Live buffer read, deny list |
| `emacs-context` | Session orientation output |
| `describe-symbol` | Symbol help without leaking values |
| `web-search` | Provider registry, SSRF URL policy (offline) |
| `send-email` | Recipient enum, offline `mailme-mail` stub |
| `eval-elisp` | Tool policy gating, safety modes, eval handler |
| `web-settings-json` | Settings API JSON shape (offline; no web server) |
| `session-context` | Session-start timestamp in system message |
| `progress-timestamp` | Progress / logging timestamps |

Run only the smokes relevant to your change, plus `load` as a baseline.

Reliable one-off invocation (with timeout):

```bash
timeout 45 emacs -batch -Q -L /path/to/eclaw \
  -l /path/to/eclaw/scripts/smoke/load.el
```

### 6. Structural edits

Whole-form replacement and symbol location use the elisp-editing skill:

```bash
~/.cursor/skills/elisp-editing/scripts/elisp-edit.sh --scan --file eclaw-tools.el
scripts/eclaw-validate-elisp.sh --locate eclaw-tools.el eclaw-deftool
```

See that skill’s `SKILL.md` for edit workflows.

## Wrapper reference

```text
scripts/eclaw-validate-elisp.sh --parens FILE ...
scripts/eclaw-validate-elisp.sh --compile
scripts/eclaw-validate-elisp.sh --require
scripts/eclaw-validate-elisp.sh --smoke NAME
scripts/eclaw-validate-elisp.sh --all FILE ...   # parens + compile + require on given files
scripts/eclaw-validate-elisp.sh --scan FILE
scripts/eclaw-validate-elisp.sh --locate FILE [SYMBOL]
```

## Troubleshooting

| Symptom | Likely fix |
|---------|------------|
| `featurep 'eclaw-eval` false / smoke load missing eval | Stale `eclaw.elc` — delete `.elc` files and recompile |
| `check-parens` / parse error | Fix unbalanced parens in the reported file; use `elisp-edit.sh --check-parens` |
| Emacs batch hangs >30s | `pkill -f "emacs -batch"`; retry one command at a time |
| Smoke passes in isolation, fails in a loop | Concurrent batch Emacs processes — run smokes sequentially |
| Compile warnings only | Usually safe to ignore unless byte-compile exits non-zero |

## Related docs

- [`README.md`](../README.md) — loading eclaw, headless batch usage
- [`PLAN.md`](../PLAN.md) — architecture; per-milestone smoke references
