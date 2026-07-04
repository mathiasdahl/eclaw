# eclaw agent skills

eclaw discovers **Agent Skills**-style capabilities under `eclaw-folder` (default `~/.eclaw/`). Only this layout is scanned:

```text
<eclaw-folder>/skills/<skill-id>/SKILL.md
```

`<skill-id>` is usually a short directory name (for example `deploy` or `lint-rules`). Names and descriptions for the model index come from the frontmatter when present.

Configure the root with `M-x customize-variable RET eclaw-folder RET` or:

```emacs-lisp
(setq eclaw-folder (expand-file-name "~/.eclaw/"))
```

## `SKILL.md` format

Optional YAML frontmatter between `---` lines:

```yaml
---
name: my-skill
description: One line describing when to use this skill.
---

# My skill

Markdown body with full instructions for the model. This body is **not**
sent automatically; the model is told to use the `read_file` tool on the skill
path when relevant.
```

If `name` is omitted, the parent directory name is used. If `description` is omitted, eclaw derives a short line from the first heading or first line of the body.

## Behaviour

- The skills section is appended to every system message built by `eclaw-system-message`.
- Paths in the index are absolute so `read_file` works regardless of `default-directory`.
- Results are cached until the set of `SKILL.md` files or their modification times change.
- `skill_write` creates or replaces skills only under `eclaw-folder/skills/`.

## Non-goals (current)

- Per-project `.eclaw/` directories are not scanned.
- Global skills directories (for example `~/.cursor/skills`) are not loaded.
- Arbitrary `SKILL.md` paths elsewhere under `eclaw-folder/` are ignored; only `skills/*/SKILL.md` counts.
