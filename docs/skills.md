# eclaw project agent skills

eclaw discovers **Agent Skills**-style capabilities in a project when a `.eclaw` directory exists in a parent of `default-directory`. Only this layout is scanned:

```text
<project-root>/.eclaw/skills/<skill-id>/SKILL.md
```

`<skill-id>` is usually a short directory name (for example `deploy` or `lint-rules`). Names and descriptions for the model index come from the frontmatter when present.

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

## Non-goals (current)

- Global skills directories (for example `~/.cursor/skills`) are not loaded.
- Arbitrary `SKILL.md` paths elsewhere under `.eclaw/` are ignored; only `.eclaw/skills/*/SKILL.md` counts.
