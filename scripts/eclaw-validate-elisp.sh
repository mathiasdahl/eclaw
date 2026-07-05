#!/usr/bin/env bash
# eclaw-validate-elisp.sh — eclaw-specific validation (uses elisp-editing skill scripts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_SCRIPTS="${ELISP_EDIT_SKILL_SCRIPTS:-$HOME/.cursor/skills/elisp-editing/scripts}"
ELISP_EDIT="$SKILL_SCRIPTS/elisp-edit.sh"
VALIDATE="$SKILL_SCRIPTS/validate-elisp.sh"

if [[ ! -x "$ELISP_EDIT" ]]; then
  echo "eclaw-validate-elisp.sh: skill scripts not found at $SKILL_SCRIPTS" >&2
  echo "Install ~/.cursor/skills/elisp-editing/ or set ELISP_EDIT_SKILL_SCRIPTS." >&2
  exit 2
fi

usage() {
  cat <<'EOF'
Usage:
  eclaw-validate-elisp.sh --parens FILE ...
  eclaw-validate-elisp.sh --locate FILE [SYMBOL]
  eclaw-validate-elisp.sh --scan FILE
  eclaw-validate-elisp.sh --compile
  eclaw-validate-elisp.sh --require
  eclaw-validate-elisp.sh --smoke NAME
  eclaw-validate-elisp.sh --all FILE ...
EOF
}

run_smoke() {
  local name="$1"
  case "$name" in
    read-file)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/read-file.el"
      ;;
    load)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/load.el"
      ;;
    web-search)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/web-search.el"
      ;;
    session-context)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/session-context.el"
      ;;
    progress-timestamp)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/progress-timestamp.el"
      ;;
    send-email)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/send-email.el"
      ;;
    buffer-read)
      emacs -batch -Q -L "$REPO_ROOT" -l "$SCRIPT_DIR/smoke/buffer-read.el"
      ;;
    *)
      echo "eclaw-validate-elisp.sh: unknown smoke test: $name" >&2
      echo "Known: read-file, load, web-search, session-context, progress-timestamp, send-email, buffer-read" >&2
      exit 2
      ;;
  esac
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

action="$1"
shift

case "$action" in
  --parens)
    "$VALIDATE" --parens "$@"
    ;;
  --locate)
    if [[ $# -eq 2 ]]; then
      "$ELISP_EDIT" --locate --file "$1" --name "$2"
    elif [[ $# -eq 1 ]]; then
      "$ELISP_EDIT" --scan --file "$1"
    else
      echo "--locate requires FILE or FILE SYMBOL" >&2
      exit 2
    fi
    ;;
  --scan)
    [[ $# -eq 1 ]] || { echo "--scan requires exactly one FILE" >&2; exit 2; }
    "$ELISP_EDIT" --scan --file "$1"
    ;;
  --compile)
    "$VALIDATE" --compile --load-path "$REPO_ROOT" \
      eclaw-skills.el eclaw-tools.el eclaw-http.el eclaw-web-search.el eclaw-mail.el eclaw.el
    ;;
  --require)
    "$VALIDATE" --require --load-path "$REPO_ROOT" eclaw
    ;;
  --smoke)
    [[ $# -eq 1 ]] || { echo "--smoke requires NAME" >&2; exit 2; }
    run_smoke "$1"
    ;;
  --all)
    [[ $# -ge 1 ]] || { echo "--all requires at least one FILE" >&2; exit 2; }
    "$VALIDATE" --parens "$@"
    "$VALIDATE" --compile --load-path "$REPO_ROOT" \
      eclaw-skills.el eclaw-tools.el eclaw-http.el eclaw-web-search.el eclaw-mail.el eclaw.el
    "$VALIDATE" --require --load-path "$REPO_ROOT" eclaw
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "eclaw-validate-elisp.sh: unknown action: $action" >&2
    usage >&2
    exit 2
    ;;
esac
