;;; eclaw.el --- Personal AI assistant for Emacs

;; Copyright (C) 2026-2026  Mathias Dahl

;; Author: Mathias Dahl <mathias.dahl@gmail.com>
;; Maintainer: Mathias Dahl <mathias.dahl@gmail.com>
;; Version: 0.0.1
;; Keywords: convenience, AI
;; URL: https://github.com/mathiasdahl/eclaw

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;;
;; eclaw is a personal AI assistant.  The primary use is general help
;; (research, writing, planning, organization, and coding when needed).
;; This file is the Emacs implementation: a synchronous orchestration runtime
;; for the OpenRouter chat completions API
;; (`https://openrouter.ai/api/v1/chat/completions').
;; It maintains one global conversation as a list of request/response
;; messages and optionally advertises local project tools (`read_file',
;; `list_directory', `glob_files', `grep_files') guarded by a sensitive-path
;; policy, plus narrow writes (`notes_write_text', `skill_write',
;; `preferences_append', `preferences_write') limited to `notes/*.txt',
;; `skills/<name>/SKILL.md', and `preferences.md' under `eclaw-folder'.
;; `glob_files' and `grep_files' use `eclaw-grep-program' (ripgrep preferred,
;; GNU grep fallback); search respects `.gitignore' by default.
;;
;; Longer term, the same assistant may run on a personal web site in the
;; cloud—with utilities and durable data stored there—while Emacs remains
;; one client/runtime.
;;
;; Source files (add the repo directory to `load-path', then `(require 'eclaw)' only;
;; sibling `eclaw-*.el' files load via `require'):
;;
;;   eclaw.el         — this file: configuration, conversation, request assembly,
;;                      orchestration, logging, UI entrypoints
;;   eclaw-skills.el  — `skills/' index block for the system message
;;   eclaw-preferences.el — `preferences.md' user memory block for the system message
;;   eclaw-tools.el   — `eclaw-deftool' registry, handlers, dispatch, sensitive-path
;;                      policy, search-tool backends
;;   eclaw-http.el    — OpenRouter POST and response accessors (see
;;                      `docs/http-transport.md')
;;   eclaw-web-search.el — `web_search' and `web_fetch' tools (Jina by default)
;;   eclaw-mail.el      — `send_email' tool (work/home only via `mailme-mail')
;;   eclaw-eval.el      — `eval_elisp' tool (full session eval; policy-gated)
;;   eclaw-notify.el    — Web Push notifications; `send_push' tool (browser chat; external pywebpush)
;;
;; Load order in `eclaw.el': `(require 'eclaw-skills)' and `(require 'eclaw-preferences)'
;; before conversation;
;; `(require 'eclaw-tools)', `(require 'eclaw-http)', `(require 'eclaw-web-search)',
;; `(require 'eclaw-mail)', `(require 'eclaw-eval)', and `(require 'eclaw-notify)' before
;; `eclaw-build-chat-payload' / `eclaw-chat'.
;;
;; Layers (logical):
;;
;; - Configuration (`eclaw.el'): API key, model id, system prompt, debug toggle.
;; - Conversation (`eclaw.el'): message alists, `eclaw-conversation' trace,
;;   archives, buffer `*eclaw*'.
;; - Agent skills (`eclaw-skills.el'): index-only `skills/*/SKILL.md' under `eclaw-folder'.
;; - Tools (`eclaw-tools.el'): registry, handlers, approval gate, path policy.
;; - Request assembly (`eclaw.el`): `eclaw-build-chat-payload' attaches `tools'
;;   from `eclaw-tool-definitions' (`eclaw-tools.el').
;; - HTTP transport (`eclaw-http.el'): `eclaw-post-completion-request',
;;   `eclaw-get-response', accessors; all POSTs through `eclaw--http-post'.
;; - Orchestration (`eclaw.el'): `eclaw-chat' loops completions until the
;;   assistant returns without `tool_calls', or a cap is reached
;;   (`eclaw-max-completions-per-prompt', `eclaw-max-tokens-per-prompt').
;; - UI / logging (`eclaw.el'): `eclaw-agent-chat', JSONL log, conversation archives.
;;
;; Conversation state (`eclaw-conversation') is the canonical execution
;; trace: user, assistant, and tool messages only (no system row).  Each
;; user turn is appended before any HTTP request; outgoing payloads are
;; built as [system] + `eclaw-conversation' via `eclaw-build-messages'.
;;
;; Limitations: blocking HTTP, global session, no streaming.
;;
;; Agent skills: optional index of `skills/*/SKILL.md` under `eclaw-folder` (Agent
;; Skills-style layout) appended to the system message; bodies are not inlined.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'seq)

;;; Configuration

(defvar eclaw-api-key
  (getenv "OPENROUTER_API_KEY")
  "Secret token for OpenRouter, sent as \"Bearer\" in `Authorization'.
Initialized from environment variable `OPENROUTER_API_KEY'; you may
`setq' this variable instead.  Empty string is treated as unset.")

(defun eclaw-get-api-key ()
  "Return the configured API key string, or signal an error if missing."
  (let ((k eclaw-api-key))
    (when (or (null k) (equal k ""))
      (error "API key not set (set OPENROUTER_API_KEY or `eclaw-api-key')"))
    k))

(defvar eclaw-system-prompt
  (concat
   "You are eclaw, a personal AI assistant. "
   "You help with a wide range of tasks—research, writing, planning, "
   "organization, and coding when the user asks. "
   "Be concise, accurate, and practical. "
   "Match the user's tone and depth; prefer clear explanations and "
   "incremental steps for technical work.\n\n"
   "You are running inside Emacs. Tool descriptions and parameters define "
   "each capability. Filesystem tools are confined to `eclaw-folder'; "
   "introspection tools read the live Emacs session and are not path-confined. "
   "Session date is in the system context below; call `get_datetime' for time of day. "
   "When the user asks you to remember a preference, use `preferences_append'; "
   "use `preferences_write' to replace the whole list. Stored preferences appear "
   "in the system context below. "
   "When asked for a plan/proposal/options first, present it and wait for "
   "explicit approval before acting.")
  "Text of the system role message prepended to every completion request.")

(require 'eclaw-skills)
(require 'eclaw-preferences)

;;; Conversation and message alists

(defgroup eclaw nil
  "Personal AI assistant for Emacs (OpenRouter-backed orchestration runtime)."
  :group 'external)

(defcustom eclaw-available-models
  '("deepseek/deepseek-v4-flash"
    "deepseek/deepseek-v4-flash:nitro"
    "deepseek/deepseek-v4-pro")
  "OpenRouter model IDs offered in the web UI model selector."
  :type '(repeat string)
  :group 'eclaw)

(defcustom eclaw-model "deepseek/deepseek-v4-flash:nitro"
  "Model identifier string passed as the `model' field of each request."
  :type 'string
  :group 'eclaw)

(defun eclaw-normalize-model (&optional model-id)
  "Return MODEL-ID if it is in `eclaw-available-models', else the first entry.
MODEL-ID defaults to `eclaw-model'.  Signal an error if the list is empty."
  (let ((id (or model-id eclaw-model)))
    (when (null eclaw-available-models)
      (error "`eclaw-available-models' is empty"))
    (if (member id eclaw-available-models)
        id
      (car eclaw-available-models))))

(defun eclaw-set-model (model-id)
  "Set `eclaw-model' to MODEL-ID when it is in `eclaw-available-models'."
  (unless (member model-id eclaw-available-models)
    (error "Model %S is not in `eclaw-available-models'" model-id))
  (setq eclaw-model model-id))

(defcustom eclaw-debug nil
  "When non-nil, emit verbose eclaw progress in the echo area.
Includes token usage, skills index reloads, and tool side-effect
details.  Orchestration progress uses `eclaw-progress-message'; cap/limit
notices are always shown."
  :type 'boolean
  :group 'eclaw)

(defcustom eclaw-url-show-status nil
  "When non-nil, show Emacs `url' library progress during eclaw HTTP.
Normally off; eclaw emits its own progress via `eclaw-progress-message'."
  :type 'boolean
  :group 'eclaw)

(defun eclaw--iso-timestamp (&optional time)
  "Return ISO 8601 timestamp for TIME (defaults to now)."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z" (or time (current-time))))

(defun eclaw-message (format-string &rest args)
  "Display a timestamped eclaw notice in the echo area / *Messages*."
  (message "[%s] %s"
           (eclaw--iso-timestamp)
           (apply #'format format-string args)))

(defun eclaw-progress-message (format-string &rest args)
  "Display FORMAT-STRING in the echo area as an eclaw progress notice."
  (apply #'eclaw-message format-string args)
  (redisplay t))

(defun eclaw-debug-message (format-string &rest args)
  "Like `eclaw-message' when `eclaw-debug' is non-nil; otherwise no-op."
  (when eclaw-debug
    (apply #'eclaw-message format-string args)))

;;;###autoload
(defun eclaw-toggle-debug ()
  "Toggle `eclaw-debug' and report the new state in the echo area."
  (interactive)
  (setq eclaw-debug (not eclaw-debug))
  (eclaw-message "eclaw debug %s" (if eclaw-debug "on" "off")))

(defcustom eclaw-folder
  (expand-file-name "~/.eclaw/")
  "Root directory for all eclaw data.
Conversation archives live in `conversations/', notes in `notes/', agent skills
in `skills/', user preferences in `preferences.md', the JSONL log as
`eclaw-log.jsonl', and tool-approval rules in `tool-approval-rules.el' — all
relative to this directory."
  :type 'directory
  :group 'eclaw)

(defun eclaw--folder ()
  "Return the absolute path to `eclaw-folder'."
  (expand-file-name eclaw-folder))

(defun eclaw--conversation-archive-dir ()
  "Return the directory for conversation archive Markdown files."
  (expand-file-name "conversations/" (eclaw--folder)))

(defun eclaw--agent-log-file ()
  "Return the path to the JSONL log file under `eclaw-folder'."
  (expand-file-name "eclaw-log.jsonl" (eclaw--folder)))

(defcustom eclaw-archive-include-tools t
  "When non-nil, append a collapsible tool-activity section to archived conversations."
  :type 'boolean
  :group 'eclaw)

(defcustom eclaw-archive-clear-buffer-on-reset t
  "When non-nil, erase buffer `*eclaw*' after archiving during `eclaw-reset-conversation'."
  :type 'boolean
  :group 'eclaw)

(defcustom eclaw-archive-on-kill-emacs nil
  "When non-nil, archive a non-empty session when Emacs exits."
  :type 'boolean
  :group 'eclaw)

(defvar eclaw-conversation nil
  "Canonical chat history for the active session, excluding system.
Each element is an alist: user (`role' user, `content'), assistant
(`role' assistant, `content' and/or `tool_calls' as returned by the
API), or tool (`role' tool, `tool_call_id', `content').  The current
user turn is appended at the start of `eclaw-chat' before any request.
Mutated by `eclaw-chat' and `eclaw-reset-conversation'.")

(defvar eclaw--session-started nil
  "Start time of the current archivable session, or nil after reset.")

(defun eclaw--usage-zero ()
  "Return a fresh usage alist with zero prompt and completion tokens."
  '((prompt_tokens . 0) (completion_tokens . 0)))

(defvar eclaw--usage-turn (eclaw--usage-zero)
  "Token usage for the current `eclaw-chat' turn (all HTTP rounds).")

(defvar eclaw--usage-conversation (eclaw--usage-zero)
  "Cumulative token usage for the active conversation since last reset.")

(defvar eclaw--usage-emacs (eclaw--usage-zero)
  "Cumulative token usage since Emacs started.")

(defun eclaw--usage-add (accum usage)
  "Add prompt/completion counts from USAGE alist into ACCUM alist."
  (let ((prompt (+ (or (alist-get 'prompt_tokens accum) 0)
                   (or (alist-get 'prompt_tokens usage) 0)))
        (completion (+ (or (alist-get 'completion_tokens accum) 0)
                       (or (alist-get 'completion_tokens usage) 0))))
    `((prompt_tokens . ,prompt) (completion_tokens . ,completion))))

(defun eclaw--usage-accumulate (usage)
  "Add USAGE from one HTTP response to turn, conversation, and Emacs totals."
  (setq eclaw--usage-turn (eclaw--usage-add eclaw--usage-turn usage)
        eclaw--usage-conversation (eclaw--usage-add eclaw--usage-conversation usage)
        eclaw--usage-emacs (eclaw--usage-add eclaw--usage-emacs usage)))

(defun eclaw--emacs-started-at ()
  "Return Emacs process start time as a `current-time' list."
  before-init-time)

(defun eclaw-usage-stats ()
  "Return token usage alists suitable for JSON encoding."
  `((turn . ,eclaw--usage-turn)
    (conversation . ,eclaw--usage-conversation)
    (emacs . ,eclaw--usage-emacs)
    (emacs_started_at . ,(format-time-string "%Y-%m-%d %H:%M"
                                             (eclaw--emacs-started-at)))))

(defun eclaw--ensure-session-started ()
  "Set `eclaw--session-started' on the first chat turn."
  (unless eclaw--session-started
    (setq eclaw--session-started (current-time))))

(defun eclaw--session-context-block ()
  "Return session-start date text for the system prompt, or \"\"."
  (if eclaw--session-started
      (let ((stamp (format-time-string "%A, %Y-%m-%d %Z"
                                     eclaw--session-started)))
        (format "\n\nSession context: today is %s.\nUse this date for time-sensitive queries and web search, not your training cutoff.\nCall get_datetime when you need the current time of day."
                stamp))
    ""))

(defun eclaw--conversation-turn-count ()
  "Return the number of user turns in `eclaw-conversation'."
  (length
   (seq-filter
    (lambda (msg) (equal (alist-get 'role msg) "user"))
    (or eclaw-conversation '()))))

(defun eclaw--conversation-first-prompt ()
  "Return content of the first user message in `eclaw-conversation', or nil."
  (let ((msg (seq-find (lambda (m) (equal (alist-get 'role m) "user"))
                       eclaw-conversation)))
    (when msg (alist-get 'content msg))))

(defun eclaw-conversation-display-messages ()
  "Return a list of user/assistant message alists for UI display.
Skips tool messages and assistant rows with empty content (tool-only rounds)."
  (let ((out nil))
    (dolist (msg (or eclaw-conversation '()))
      (let ((role (alist-get 'role msg))
            (content (alist-get 'content msg)))
        (when (and (member role '("user" "assistant"))
                   (stringp content)
                   (not (string-empty-p content)))
          (push `((role . ,role) (content . ,content)) out))))
    (nreverse out)))

(defun eclaw--session-has-content-p ()
  "Non-nil when the current session has content worth archiving."
  (or (and (get-buffer "*eclaw*")
           (with-current-buffer (get-buffer "*eclaw*")
             (string-match-p "[^[:space:]]" (buffer-string))))
      (and eclaw-conversation (> (length eclaw-conversation) 0))))

(defun eclaw--conversation-slug (prompt)
  "Return a filename slug derived from user PROMPT, or nil when empty."
  (when (and prompt (not (string-empty-p (string-trim prompt))))
    (let* ((s (downcase (string-trim prompt)))
           (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
           (s (string-trim s "-")))
      (when (> (length s) 40)
        (setq s (substring s 0 40)))
      (unless (string-empty-p s) s))))

(defun eclaw--conversation-archive-path (time slug)
  "Return absolute archive file path for TIME and optional SLUG."
  (let* ((dir (eclaw--conversation-archive-dir))
         (stamp (format-time-string "%Y-%m-%d_%H%M%S" time))
         (name (if (and slug (not (string-empty-p slug)))
                   (format "%s_%s.md" stamp slug)
                 (format "%s.md" stamp))))
    (expand-file-name name dir)))

(defun eclaw--conversation-render-transcript ()
  "Return transcript text from buffer `*eclaw*', or \"\" if the buffer is missing."
  (if-let ((buf (get-buffer "*eclaw*")))
      (with-current-buffer buf
        (string-trim (buffer-string)))
    ""))

(defun eclaw--conversation-render-one-tool-call (tool-call)
  "Return one markdown bullet for TOOL-CALL alist."
  (let* ((fn-spec (alist-get 'function tool-call))
         (name (or (alist-get 'name fn-spec) "unknown"))
         (args (string-trim (or (alist-get 'arguments fn-spec) ""))))
    (if (or (string-empty-p args) (string-equal args "{}"))
        (format "- **%s**" name)
      (let ((max 120))
        (if (> (length args) max)
            (format "- **%s** `%s…`" name (substring args 0 max))
          (format "- **%s** `%s`" name args))))))

(defun eclaw--conversation-render-tools ()
  "Return a collapsible markdown appendix for tool rounds in `eclaw-conversation'."
  (when (and eclaw-archive-include-tools eclaw-conversation)
    (let ((rounds nil)
          (round 0))
      (dolist (msg eclaw-conversation)
        (when (and (equal (alist-get 'role msg) "assistant")
                   (alist-get 'tool_calls msg))
          (setq round (1+ round))
          (push
           (concat "### Tool round " (number-to-string round) "\n"
                   (mapconcat #'eclaw--conversation-render-one-tool-call
                              (alist-get 'tool_calls msg)
                              "\n"))
           rounds)))
      (when rounds
        (concat "\n\n<details>\n<summary>Tool activity</summary>\n\n"
                (mapconcat #'identity (nreverse rounds) "\n\n")
                "\n\n</details>\n")))))

(defun eclaw--conversation-archive-frontmatter (ended-time)
  "Return YAML frontmatter for an archive ending at ENDED-TIME."
  (format
   "---\nid: %s\nstarted: %s\nended: %s\nmodel: %s\nfolder: %s\nturns: %s\nsource: eclaw-archive\n---\n\n"
   (format-time-string "%Y-%m-%dT%H:%M:%S%z" ended-time)
   (if eclaw--session-started
       (format-time-string "%Y-%m-%dT%H:%M:%S%z" eclaw--session-started)
     "")
   (format-time-string "%Y-%m-%dT%H:%M:%S%z" ended-time)
   eclaw-model
   (eclaw--folder)
   (eclaw--conversation-turn-count)))

(defun eclaw-archive-current-conversation ()
  "Save the current session to a Markdown file under `eclaw-folder'/`conversations/'.
Return the written file path, or nil when there is nothing to archive."
  (when (eclaw--session-has-content-p)
    (let* ((ended (current-time))
           (path (eclaw--conversation-archive-path
                  ended
                  (eclaw--conversation-slug (eclaw--conversation-first-prompt))))
           (dir (file-name-directory path))
           (transcript (eclaw--conversation-render-transcript))
           (tools (or (eclaw--conversation-render-tools) ""))
           (content (concat (eclaw--conversation-archive-frontmatter ended)
                            transcript
                            tools)))
      (make-directory dir t)
      (with-temp-file path
        (set-buffer-file-coding-system 'utf-8-unix)
        (insert content))
      path)))

(defun eclaw--clear-eclaw-buffer ()
  "Erase buffer `*eclaw*' when it exists, preserving View mode."
  (when-let ((buf (get-buffer "*eclaw*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (when view-mode (view-mode -1))
        (erase-buffer)
        (view-mode 1)))))

(defun eclaw-reset-conversation ()
  "Archive the current session, clear `eclaw-conversation', and start fresh.
When archiving fails, the session is left unchanged."
  (interactive)
  (when (eclaw--session-has-content-p)
    (condition-case err
        (let ((path (eclaw-archive-current-conversation)))
          (unless path
            (user-error "Archive produced no file"))
          (eclaw-message "eclaw: conversation archived to %s" path))
      (error
       (user-error "Archive failed: %s" (error-message-string err)))))
  (setq eclaw-conversation nil)
  (setq eclaw--session-started nil)
  (setq eclaw--usage-conversation (eclaw--usage-zero))
  (when eclaw-archive-clear-buffer-on-reset
    (eclaw--clear-eclaw-buffer))
  (eclaw-message "eclaw conversation reset"))

(defun eclaw-system-message ()
  "Return one system message alist using `eclaw-system-prompt'.
When `preferences.md' exists under `eclaw-folder', append a user preferences block.
When skills exist under `eclaw-folder'/`skills/', append an index-only skills section.
When `eclaw--session-started' is set, append a frozen session context block."
  `((role . "system")
    (content . ,(concat eclaw-system-prompt
                        (eclaw--preferences-system-block)
                        (eclaw--skills-system-block)
                        (eclaw--session-context-block)))))

(defun eclaw-user-message (content)
  "Return a user message alist with string CONTENT."
  `((role . "user")
    (content . ,content)))

(defun eclaw-assistant-message (content)
  "Return an assistant message alist with string CONTENT (plain reply)."
  `((role . "assistant")
    (content . ,content)))

(defun eclaw-tool-message (tool-call-id content)
  "Return a tool result message for TOOL-CALL-ID with string CONTENT."
  `((role . "tool")
    (tool_call_id . ,tool-call-id)
    (content . ,content)))

(defun eclaw-build-messages ()
  "Build the outgoing message list from canonical `eclaw-conversation'.
Returns [system] + conversation as a flat list suitable for
`eclaw-build-chat-payload'.  The conversation must already include
the current user turn (and any in-flight assistant/tool rows)."
  (append (list (eclaw-system-message)) eclaw-conversation nil))

(defun eclaw--normalize-assistant-message (message)
  "Return a compact assistant MESSAGE alist for conversation storage.
Keeps only `role', `content', and `tool_calls' (when present)."
  (when message
    (let ((out (list (cons 'role "assistant")
                     (cons 'content (alist-get 'content message)))))
      (when-let ((tool-calls (alist-get 'tool_calls message)))
        (push (cons 'tool_calls tool-calls) out))
      out)))

(defun eclaw-append-assistant-reply (content)
  "Append assistant CONTENT to `eclaw-conversation'.
CONTENT may be nil; it is stored as an empty string."
  (setq eclaw-conversation
        (nconc eclaw-conversation
               (list (eclaw-assistant-message (or content ""))))))


;;; Request assembly (`eclaw-http.el' for POST, parsing, accessors)

(require 'eclaw-tools)
(require 'eclaw-http)
(require 'eclaw-web-search)
(require 'eclaw-mail)
(require 'eclaw-eval)
(require 'eclaw-notify)

(defun eclaw-tool-get-datetime ()
  "Return current wall-clock time and session start for the model."
  (let ((now (current-time)))
    (concat
     (format "now: %s\n"
             (format-time-string "%A, %Y-%m-%d %H:%M:%S %Z" now))
     (if eclaw--session-started
         (format "session_started: %s\n"
                 (eclaw--iso-timestamp eclaw--session-started))
       ""))))

(defun eclaw--register-get-datetime-tool ()
  "Register `get_datetime' at load time."
  (eclaw--register-tool
   "get_datetime"
   "Return the current wall-clock date and time. Session date is in the system message; call when time of day matters."
   (eclaw--deftool-params-to-schema '())
   (lambda (_args) (eclaw-tool-get-datetime))))

(eclaw--register-get-datetime-tool)

(defun eclaw-build-chat-payload (messages)
  "Return the JSON-serializable request alist for message list MESSAGES.
MESSAGES must be a list of message alists; it is stored under key `messages'
as a vector.  Adds `tools' when `eclaw-tool-definitions' returns non-nil."
  (let ((base `((model . ,eclaw-model)
               (messages . ,(vconcat messages))))
        (tools (eclaw-tool-definitions)))
    (if tools
        (append base `((tools . ,tools)))
      base)))

;;; Orchestration

(defvar eclaw-max-completions-per-prompt 32
  "Maximum OpenRouter completions in a single `eclaw-chat' invocation.
Counts every HTTP round-trip, including tool follow-ups.  When exceeded,
a synthetic assistant message is appended and the turn ends.")

(defvar eclaw-max-tokens-per-prompt 200000
  "Soft ceiling on cumulative `total_tokens' from each response's `usage'.
Sum updates after every completion; when it exceeds this value, any
pending `tool_calls' receive synthetic results and the turn ends without
further requests.  (Missing `usage' fields do not add to the sum.)")

(defun eclaw-chat (prompt)
  "Send user text PROMPT to the model; return the final assistant string.

If the model returns `tool_calls', every call is executed and the
conversation is extended with tool results; this repeats until the model
produces a normal reply or `eclaw-max-completions-per-prompt' or
`eclaw-max-tokens-per-prompt' stops the loop.

When a limit fires, the result string describes the stop reason and the
conversation is left in a valid shape for the next user message.  Pending
`tool_calls' still receive one synthetic tool result per `tool_call_id' (see
`docs/tool-approval.md').

The user turn is appended to `eclaw-conversation' before the first
request so history matches what was sent even when a request fails.
Each HTTP exchange is logged."
  (eclaw--ensure-session-started)
  (setq eclaw--usage-turn (eclaw--usage-zero))
  (setq eclaw-conversation
        (nconc eclaw-conversation (list (eclaw-user-message prompt))))
  (let* ((messages (eclaw-build-messages))
         (total-tokens 0)
         (completions 0)
         (reply
          (catch 'eclaw-chat-done
            (while t
             (when (>= completions eclaw-max-completions-per-prompt)
               (let ((msg (concat "[eclaw: stopped — max completions per prompt ("
                                   (number-to-string eclaw-max-completions-per-prompt)
                                   ") reached]")))
                 (eclaw-message "eclaw: %s" msg)
                 (setq eclaw-conversation
                       (nconc eclaw-conversation
                              (list (eclaw-assistant-message msg))))
                 (throw 'eclaw-chat-done msg)))
             (setq completions (1+ completions))
             (eclaw-progress-message "eclaw: waiting for model (round %d)…" completions)
             (let* ((payload (eclaw-build-chat-payload messages))
                    (response (eclaw-post-completion-request payload))
                    (usage (alist-get 'usage response)))
               (eclaw-log payload response)
               (when usage
                 (eclaw-report-usage usage)
                 (eclaw--usage-accumulate usage))
               (when-let ((tok (and usage (alist-get 'total_tokens usage))))
                 (setq total-tokens (+ total-tokens tok)))
               (let* ((tool-calls (eclaw-get-tool-calls response))
                      (assistant-msg (eclaw-get-message response))
                      (has-tools (and tool-calls (> (length tool-calls) 0)))
                      (over-tokens (> total-tokens eclaw-max-tokens-per-prompt))
                      (synth-reason
                       (when over-tokens
                         (concat "cumulative token limit for this prompt exceeded (>"
                                 (number-to-string eclaw-max-tokens-per-prompt)
                                 " total_tokens)"))))
                 (if has-tools
                     (progn
                       (unless assistant-msg
                         (error "eclaw: assistant message missing despite tool_calls"))
                       (setq eclaw-conversation
                             (nconc eclaw-conversation
                                    (cons (eclaw--normalize-assistant-message
                                           assistant-msg)
                                          (eclaw--tool-result-messages
                                           tool-calls synth-reason))))
                       (when over-tokens
                         (let ((note (concat "[eclaw: turn stopped — "
                                             synth-reason "]")))
                           (eclaw-message "eclaw: %s" note)
                           (setq eclaw-conversation
                                 (nconc eclaw-conversation
                                        (list (eclaw-assistant-message note))))
                           (throw 'eclaw-chat-done note)))
                       (setq messages (eclaw-build-messages)))
                   (let ((content (or (eclaw-get-content response) "")))
                     (when over-tokens
                       (setq content
                             (concat content
                                     "\n\n[eclaw: cumulative token limit for this prompt exceeded]"))
                       (eclaw-message "eclaw: token limit exceeded for this prompt"))
                     (eclaw-append-assistant-reply content)
                     (throw 'eclaw-chat-done content)))))))))
    (eclaw-notify-chat-complete prompt reply)
    reply))

(defun eclaw-report-usage (usage)
  "When `eclaw-debug' is non-nil, display token counts from USAGE in the echo area."
  (eclaw-debug-message
   "Prompt: %s  Completion: %s  Total: %s"
   (alist-get 'prompt_tokens usage)
   (alist-get 'completion_tokens usage)
   (alist-get 'total_tokens usage)))

;;; Logging (each HTTP exchange)

(defun eclaw-log (request-payload response)
  "Record REQUEST-PAYLOAD and RESPONSE via `eclaw-append-json-log' (one line)."
  (eclaw-append-json-log
   `((timestamp . ,(eclaw--iso-timestamp))
     (model . ,eclaw-model)
     (request . ,request-payload)
     (response . ,response))))

;;; Interactive entry points

(defun eclaw--eclaw-buffer-append (text)
  "Append TEXT at point-max in `*eclaw*', then restore View mode.
View mode blocks insertion; eclaw exits it briefly, appends, and turns it
back on so the user keeps view-mode navigation for reading the transcript."
  (let ((inhibit-read-only t))
    (when view-mode (view-mode -1))
    (goto-char (point-max))
    (insert text)
    (view-mode 1)))

(defun eclaw--eclaw-buffer-setup ()
  "Prepare the current buffer as the View-mode `*eclaw*' transcript."
  (require 'markdown-mode nil t)
  (if (fboundp 'markdown-mode)
      (markdown-mode)
    (text-mode))
  (unless view-mode
    (view-mode 1)))

(defun eclaw-agent-chat (prompt)
  "Prompt for PROMPT, call `eclaw-chat', append exchange to buffer `*eclaw*'.
The user turn is written to `*eclaw*' before the (possibly multi-round)
HTTP exchange so follow-up prompts are visible while tools run.

The transcript buffer uses View mode for reading; new content is appended
by eclaw only.

PROMPT is read interactively when called as a command."
  (interactive "sPrompt: ")
  (let ((buf (get-buffer-create "*eclaw*")))
    (with-current-buffer buf
      (eclaw--eclaw-buffer-setup)
      (eclaw--eclaw-buffer-append
       (concat "\n\nYou:\n" prompt "\n\nAssistant:\n"))
      (display-buffer (current-buffer)))
    (condition-case err
        (with-current-buffer buf
          (eclaw--eclaw-buffer-append (eclaw-chat prompt))
          (display-buffer (current-buffer)))
      (error
       (with-current-buffer buf
         (eclaw--eclaw-buffer-append (format "Error: %s" (error-message-string err)))
         (display-buffer (current-buffer)))
       (signal (car err) (cdr err))))))

(defun eclaw-explain-buffer ()
  "Send the current buffer's text as code to be explained via `eclaw-agent-chat'."
  (interactive)
  (eclaw-agent-chat
   (concat
    "Explain this code:\n\n"
    (buffer-string))))

(defun eclaw-save-conversation ()
  "Save the current eclaw session to a Markdown archive file."
  (interactive)
  (if (eclaw--session-has-content-p)
      (condition-case err
          (let ((path (eclaw-archive-current-conversation)))
            (if path
                (eclaw-message "eclaw: conversation saved to %s" path)
              (user-error "Archive produced no file")))
        (error
         (user-error "Archive failed: %s" (error-message-string err))))
    (user-error "No conversation to save")))

(defun eclaw--list-conversation-files ()
  "Return archive `.md' files sorted newest first."
  (let ((dir (eclaw--conversation-archive-dir)))
    (when (file-directory-p dir)
      (sort
       (directory-files dir nil "\\`[^.].*\\.md\\'")
       (lambda (a b)
         (> (file-attribute-modification-time (file-attributes (expand-file-name a dir)))
            (file-attribute-modification-time (file-attributes (expand-file-name b dir)))))))))

(defun eclaw--conversation-file-label (file)
  "Return a completion label for archive FILE."
  (let* ((full (expand-file-name file (eclaw--conversation-archive-dir)))
         (mtime (file-attribute-modification-time (file-attributes full)))
         (stamp (when mtime (format-time-string "%Y-%m-%d %H:%M" mtime))))
    (if stamp
        (format "%s  %s" stamp (file-name-nondirectory file))
      (file-name-nondirectory file))))

(defun eclaw-open-conversation (&optional file)
  "Open a saved conversation archive in a read-only markdown buffer."
  (interactive
   (let* ((dir (eclaw--conversation-archive-dir))
          (files (eclaw--list-conversation-files))
          (candidates
           (mapcar (lambda (f)
                     (cons (eclaw--conversation-file-label f) f))
                   files)))
     (unless files
       (user-error "No conversation archives in %s" dir))
     (list (completing-read "Conversation: " candidates nil t))))
  (let ((path (expand-file-name file (eclaw--conversation-archive-dir))))
    (unless (file-readable-p path)
      (user-error "Conversation file not readable: %s" path))
    (find-file-read-only path)
    (eclaw--eclaw-buffer-setup)))

(defun eclaw-list-conversations ()
  "Open `eclaw-folder'/`conversations/' in Dired."
  (interactive)
  (let ((dir (eclaw--conversation-archive-dir)))
    (make-directory dir t)
    (dired dir)))

(defun eclaw--maybe-archive-on-kill-emacs ()
  "Archive the current session on Emacs exit when configured."
  (when (and eclaw-archive-on-kill-emacs (eclaw--session-has-content-p))
    (condition-case nil
        (eclaw-archive-current-conversation)
      (error nil))))

(add-hook 'kill-emacs-hook #'eclaw--maybe-archive-on-kill-emacs)

;;; JSONL log file

(defun eclaw-append-json-log (data)
  "Append DATA, JSON-encoded, as one line to the JSONL log under `eclaw-folder'."
  (let ((path (eclaw--agent-log-file)))
    (make-directory (file-name-directory path) t)
    (with-temp-buffer
      (insert
       (json-encode data))
      ;; JSONL separator
      (goto-char (point-max))
      (insert "\n")
      (append-to-file
       (point-min)
       (point-max)
       path))))

(provide 'eclaw)
;;; eclaw.el ends here
