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
;; policy, plus narrow writes (`notes_write_text', `skill_write') limited to
;; `notes/*.txt' and `.eclaw/skills/<name>/SKILL.md' under the `.eclaw' root.
;; `glob_files' and `grep_files' use `eclaw-grep-program' (ripgrep preferred,
;; GNU grep fallback); search respects `.gitignore' by default.
;;
;; Longer term, the same assistant may run on a personal web site in the
;; cloud—with utilities and durable data stored there—while Emacs remains
;; one client/runtime.
;;
;; Layers (all in this file; transport is a distinct logical section):
;;
;; - Configuration: API key, model id, system prompt; tools via `eclaw-deftool';
;;   sensitive-path defaults via `eclaw-sensitive-path-prefixes' /
;;   `eclaw-sensitive-path-files'.
;; - Message builders: alists shaped like OpenAI chat messages; serialized
;;   with `json-encode' (symbol keys, vectors for `messages' array).
;; - HTTP transport: `eclaw-build-chat-payload', `eclaw-post-completion-request',
;;   `eclaw-get-response', and response accessors—no
;;   conversation mutation or logging.  All POSTs go through `eclaw--http-post'
;;   (unibyte UTF-8 encoding; see `docs/http-transport.md').
;; - Orchestration: `eclaw-chat' loops completions until the assistant returns
;;   without `tool_calls', or a cap is reached (`eclaw-max-completions-per-prompt',
;;   `eclaw-max-tokens-per-prompt').  Each assistant message may request multiple
;;   tools; every call is executed and a matching `role: tool' row is appended.
;; - UI: `eclaw-agent-chat' appends to buffer `*eclaw*'; logging writes
;;   JSON lines to `eclaw-agent-log-file'; conversation archives write
;;   Markdown files to `eclaw-conversation-archive-dir' (on reset or manual save).
;;
;; Conversation state (`eclaw-conversation') is the canonical execution
;; trace: user, assistant, and tool messages only (no system row).  Each
;; user turn is appended before any HTTP request; outgoing payloads are
;; built as [system] + `eclaw-conversation' via `eclaw-build-messages'.
;;
;; Limitations: blocking HTTP, global session, no streaming.
;;
;; Project agent skills: optional index of `.eclaw/skills/*/SKILL.md` (Agent
;; Skills-style layout) appended to the system message; bodies are not inlined.

;;; Code:

(require 'url)
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

(defvar eclaw-model
  "deepseek/deepseek-v4-flash"
  "Model identifier string passed as the `model' field of each request.")

(defvar eclaw-system-prompt
  (concat
   "You are eclaw, a personal AI assistant. "
   "You help with a wide range of tasks—research, writing, planning, "
   "organization, and coding when the user asks. "
   "Be concise, accurate, and practical. "
   "Match the user's tone and depth; prefer clear explanations and "
   "incremental steps for technical work.\n\n"
   "You are running inside Emacs. When the user needs project or code "
   "context, use `glob_files' to find files by name, `grep_files' to search "
   "contents (default `output_mode' files_with_matches, then `read_file'), and "
   "`list_directory' for a single directory listing. Patterns in `grep_files' "
   "are ripgrep regexes; escape metacharacters when searching for literal text. "
   "Use `include_ignored: true' only when gitignored or build output must be searched. "
   "When the user wants durable notes, use `notes_write_text' to create or update "
   "only `.txt' files under the project's `notes/' directory (paths are relative to "
   "`notes/`; the tool prepends `YYYY-MM-DD_HHMMSS-' to the file name). When guidance "
   "should persist as reusable agent instructions, use "
   "`skill_write' to add or replace `.eclaw/skills/<skill_dir>/SKILL.md' "
   "(skill_dir uses only letters, digits, hyphen, underscore; max length 64). "
   "Both tools apply only under the project directory that contains `.eclaw'.")
  "Text of the system role message prepended to every completion request.")

;;; Project skills (Agent Skills index, project-local only)

(defvar eclaw--skills-cache nil
  "Internal plist used by `eclaw--project-skills-index'.
Keys are :root (string directory), :signature (string), :skills (list).")

(defun eclaw--file-mtime-float (file)
  "Return modification time of FILE as a float, for stable comparisons."
  (let ((attr (file-attributes file)))
    (unless attr
      (error "Cannot stat %S" file))
    (float-time
     (if (fboundp 'file-attribute-modification-time)
         (file-attribute-modification-time attr)
       (nth 5 attr)))))

(defun eclaw--skills-project-root ()
  "Return project directory containing `.eclaw', or nil if none.
Uses `default-directory' as the starting point."
  (when-let ((dir (locate-dominating-file default-directory ".eclaw")))
    (directory-file-name (expand-file-name dir))))

(defun eclaw--skill-yaml-get (key beg end)
  "In the current buffer, read simple `KEY: value' line between BEG and END.
Value is the rest of the line after the first colon, `string-trim'ed.
Returns nil if missing or empty."
  (save-restriction
    (narrow-to-region beg end)
    (goto-char (point-min))
    (when (re-search-forward (concat "^" (regexp-quote key) ":[ \t]*") nil t)
      (let* ((raw (buffer-substring-no-properties (point) (line-end-position)))
             (val (string-trim raw)))
        (when (and (> (length val) 1)
                   (eq (aref val 0) ?\")
                   (eq (aref val (1- (length val))) ?\"))
          (setq val (substring val 1 (1- (length val)))))
        (unless (string-empty-p val)
          val)))))

(defun eclaw--skill-fallback-description (body-beg body-end)
  "From Markdown body between BODY-BEG and BODY-END, derive a short summary."
  (save-restriction
    (narrow-to-region body-beg body-end)
    (goto-char (point-min))
    (skip-chars-forward "\n\t ")
    (cond
     ((eobp)
      "No description.")
     ((looking-at "^#\\(?:#+\\)?[ \t]+\\(.*\\)$")
      (string-trim (match-string-no-properties 1)))
     (t
      (string-trim (buffer-substring-no-properties (point) (line-end-position)))))))

(defun eclaw--parse-skill-md (filepath default-dir-name)
  "Parse SKILL.md at FILEPATH for index fields.
Return plist (:name :description :path).  DEFAULT-DIR-NAME is used when
`name' is missing from YAML frontmatter."
  (with-temp-buffer
    (insert-file-contents-literally filepath)
    (set-buffer-multibyte t)
    (let (name description body-beg)
      (goto-char (point-min))
      (if (not (looking-at "^---[ \t]*\n"))
          (setq body-beg (point-min))
        (forward-line)
        (let ((fm-start (point))
              fm-end)
          (if (not (re-search-forward "^---[ \t]*\n" nil t))
              (progn
                (setq fm-end (point-max))
                (setq name (eclaw--skill-yaml-get "name" fm-start fm-end))
                (setq description (eclaw--skill-yaml-get "description" fm-start fm-end))
                (setq body-beg (point-max)))
            (setq fm-end (match-beginning 0))
            (setq name (eclaw--skill-yaml-get "name" fm-start fm-end))
            (setq description (eclaw--skill-yaml-get "description" fm-start fm-end))
            (setq body-beg (point)))))
      (unless name
        (setq name default-dir-name))
      (unless description
        (setq description (eclaw--skill-fallback-description body-beg (point-max))))
      (list :name name
            :description description
            :path (expand-file-name filepath)))))

(defun eclaw--path-is-project-skill-md-p (path-in)
  "Non-nil if PATH-IN matches a path from `eclaw--project-skills-index'."
  (when (and path-in (not (string-empty-p path-in)))
    (let ((file (expand-file-name path-in))
          (hit nil))
      (dolist (s (or (eclaw--project-skills-index) nil))
        (when (string-equal file (plist-get s :path))
          (setq hit t)))
      hit)))

(defun eclaw--skills-load-from-directory (skills-dir)
  "Scan SKILLS-DIR once; return plist (:signature :skills).
:signature changes when any `SKILL.md' mtime changes; :skills is sorted by name."
  (if (not (file-directory-p skills-dir))
      (list :signature "" :skills nil)
    (let (parts skills)
      (dolist (entry (directory-files skills-dir nil "^[^.]" t))
        (let* ((sub (expand-file-name entry skills-dir))
               (md (expand-file-name "SKILL.md" sub)))
          (when (and (file-directory-p sub) (file-exists-p md))
            (push (format "%s:%f" md (eclaw--file-mtime-float md)) parts)
            (condition-case err
                (push (eclaw--parse-skill-md md entry) skills)
              (error (eclaw-debug-message "eclaw: skipping skill %S: %S" md err))))))
      (list :signature (mapconcat #'identity (sort parts #'string<) "|")
            :skills (sort skills (lambda (a b)
                                   (string-lessp (plist-get a :name)
                                                 (plist-get b :name))))))))

(defun eclaw--project-skills-index ()
  "Return cached list of project skill plists, or nil if none.
Skills are discovered only from `.eclaw/skills/*/SKILL.md' relative to the
project root (`eclaw--skills-project-root').  List is sorted by name."
  (let ((root (eclaw--skills-project-root)))
    (cond
     ((null root)
      nil)
     (t
      (let* ((skills-dir (expand-file-name "skills" (expand-file-name ".eclaw" root)))
             (loaded (eclaw--skills-load-from-directory skills-dir))
             (sig (plist-get loaded :signature))
             (cached eclaw--skills-cache))
        (if (and cached
                 (equal root (plist-get cached :root))
                 (equal sig (plist-get cached :signature)))
            (plist-get cached :skills)
            (let* ((skills (plist-get loaded :skills))
                   (plist (list :root root :signature sig :skills skills)))
            (setq eclaw--skills-cache plist)
            (eclaw-debug-message
             "eclaw: project skills index %s (%d skill%s)"
             (if skills "loaded" "empty")
             (length skills)
             (if (= 1 (length skills)) "" "s"))
            skills)))))))

(defun eclaw--skills-system-block ()
  "Return Markdown text listing project skills for the system prompt, or \"\"."
  (if-let ((skills (eclaw--project-skills-index)))
      (concat "\n\n## Project agent skills (index only)\n\n"
              "These entries follow the Agent Skills convention (each skill is a "
              "directory under `.eclaw/skills/' with a `SKILL.md'). Only this index "
              "is included here; the full instructions live in each file path below. "
              "When the user's task fits a skill's description, use the `read_file' "
              "tool on that path first, then follow the skill.\n\n"
              (mapconcat
               (lambda (s)
                 (format "- **%s**: %s\n  Path: `read_file` with path `%s`."
                         (plist-get s :name)
                         (plist-get s :description)
                         (plist-get s :path)))
               skills
               "\n"))
    ""))

;;; Conversation and message alists

(defgroup eclaw nil
  "Personal AI assistant for Emacs (OpenRouter-backed orchestration runtime)."
  :group 'external)

(defcustom eclaw-data-dir
  (expand-file-name "~/.eclaw/")
  "Directory under the user's home for eclaw data (archives, logs, etc.)."
  :type 'directory
  :group 'eclaw)

(defcustom eclaw-conversation-archive-dir
  (expand-file-name "conversations/" (expand-file-name eclaw-data-dir))
  "Directory for Markdown conversation archives written by `eclaw-archive-current-conversation'."
  :type 'directory
  :group 'eclaw)

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

(defvar eclaw--session-project nil
  "`default-directory' at session start, stored as an absolute path.")

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
  (let* ((dir (expand-file-name eclaw-conversation-archive-dir))
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
   "---\nid: %s\nstarted: %s\nended: %s\nmodel: %s\nproject: %s\nturns: %s\nsource: eclaw-archive\n---\n\n"
   (format-time-string "%Y-%m-%dT%H:%M:%S%z" ended-time)
   (if eclaw--session-started
       (format-time-string "%Y-%m-%dT%H:%M:%S%z" eclaw--session-started)
     "")
   (format-time-string "%Y-%m-%dT%H:%M:%S%z" ended-time)
   eclaw-model
   (or eclaw--session-project (expand-file-name default-directory))
   (eclaw--conversation-turn-count)))

(defun eclaw-archive-current-conversation ()
  "Save the current session to a Markdown file under `eclaw-conversation-archive-dir'.
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
          (message "eclaw: conversation archived to %s" path))
      (error
       (user-error "Archive failed: %s" (error-message-string err)))))
  (setq eclaw-conversation nil)
  (setq eclaw--session-started nil)
  (setq eclaw--session-project nil)
  (when eclaw-archive-clear-buffer-on-reset
    (eclaw--clear-eclaw-buffer))
  (message "eclaw conversation reset"))

(defun eclaw-system-message ()
  "Return one system message alist using `eclaw-system-prompt'.
When the current `default-directory' is under a project with
`.eclaw/skills/*/SKILL.md', append an index-only skills section."
  `((role . "system")
    (content . ,(concat eclaw-system-prompt (eclaw--skills-system-block)))))

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

;;; Tools (registry and `eclaw-deftool')

(defvar eclaw--tool-registry (make-hash-table :test 'equal)
  "Maps tool name string to plist (:description :parameters :handler).
Populated by `eclaw-deftool'.")

(defvar eclaw-tools-enabled t
  "When non-nil, include registered tools in outgoing chat requests.
When nil, behave like text-only completions regardless of registry contents.")

(defcustom eclaw-debug nil
  "When non-nil, emit verbose eclaw progress in the echo area.
Includes HTTP request notices, token usage, project skills index reloads,
and tool side-effect details.  Tool dispatch lines and cap/limit notices
are always shown."
  :type 'boolean
  :group 'eclaw)

(defun eclaw-debug-message (format-string &rest args)
  "Like `message' when `eclaw-debug' is non-nil; otherwise no-op."
  (when eclaw-debug
    (apply #'message format-string args)))

;;;###autoload
(defun eclaw-toggle-debug ()
  "Toggle `eclaw-debug' and report the new state in the echo area."
  (interactive)
  (setq eclaw-debug (not eclaw-debug))
  (message "eclaw debug %s" (if eclaw-debug "on" "off")))

(defcustom eclaw-sensitive-path-prefixes
  '("~/.ssh/" "~/.gnupg/" "~/.aws/" "~/.azure/" "~/.kube/")
  "Directory prefixes blocked for read/list/search tools.
A path is blocked when its `file-truename' lies inside one of these
directories (after expanding \"~\")."
  :type '(repeat string)
  :group 'eclaw)

(defcustom eclaw-sensitive-path-files
  '("~/.git-credentials"
    "~/.netrc"
    "~/.pgpass"
    "~/.my.cnf"
    "~/.pypirc"
    "~/.npmrc"
    "~/.docker/config.json"
    "~/.bash_history"
    "~/.zsh_history"
    "~/.history"
    "~/.config/gcloud/application_default_credentials.json"
    "~/.config/gh/hosts.yml")
  "Exact file paths blocked for read/list/search tools.
Compared via `file-truename' after `expand-file-name'."
  :type '(repeat string)
  :group 'eclaw)

(defconst eclaw--sensitive-path-msg
  "Error: access denied (eclaw sensitive path policy)."
  "Constant denial message returned to the model for blocked paths.")

(defcustom eclaw-grep-program "rg"
  "External program for `glob_files' and `grep_files': ripgrep (\"rg\") or GNU grep (\"grep\").
Ripgrep is preferred; when the chosen program is missing, the other is tried."
  :type '(choice (const :tag "ripgrep" "rg")
                 (const :tag "GNU grep" "grep"))
  :group 'eclaw)

(defcustom eclaw-rg-respect-gitignore t
  "When non-nil, ripgrep honors `.gitignore' unless a tool call sets `include_ignored'."
  :type 'boolean
  :group 'eclaw)

(defcustom eclaw-rg-default-head-limit 250
  "Default maximum entries returned by `glob_files' and `grep_files'."
  :type 'integer
  :group 'eclaw)

(defconst eclaw-rg-max-pattern-length 500
  "Maximum allowed length of a `grep_files' pattern string.")

(defconst eclaw-rg-max-head-limit 1000
  "Hard cap on `head_limit' for search tools (also applies when `head_limit' is 0).")

(defun eclaw--canonical-path (path)
  "Return `file-truename' of expanded PATH, or nil if resolution fails."
  (condition-case nil
      (file-truename (expand-file-name path))
    (error nil)))

(defun eclaw--path-under-sensitive-prefix-p (canonical-path prefix)
  "Non-nil if CANONICAL-PATH names PREFIX or a path inside it."
  (condition-case nil
      (let ((pre (file-name-as-directory (file-truename (expand-file-name prefix)))))
        (unless (string-empty-p pre)
          (or (string-equal (directory-file-name pre)
                            (directory-file-name canonical-path))
              (string-prefix-p pre (concat canonical-path "/")))))
    (error nil)))

(defun eclaw--path-sensitive-p (path)
  "Non-nil when PATH must not be read, listed, or searched by tools."
  (when-let ((canon (eclaw--canonical-path path)))
    (catch 'eclaw-sensitive
      (dolist (pfx eclaw-sensitive-path-prefixes)
        (when (eclaw--path-under-sensitive-prefix-p canon pfx)
          (throw 'eclaw-sensitive t)))
      (dolist (f eclaw-sensitive-path-files)
        (when-let ((cf (eclaw--canonical-path f)))
          (when (string-equal canon cf)
            (throw 'eclaw-sensitive t))))
      nil)))

(defun eclaw--invalidate-skills-cache ()
  "Clear `eclaw--skills-cache' so the next index rebuilds from disk."
  (setq eclaw--skills-cache nil))

(defun eclaw--canonical-under-directory-p (canon-path canon-dir)
  "Non-nil when CANON-PATH is CANON-DIR or strictly inside it.
Both values should be absolute `file-truename' paths; CANON-DIR may name a
directory with or without a trailing slash."
  (when (and canon-path canon-dir)
    (let ((pre (file-name-as-directory canon-dir)))
      (unless (string-empty-p pre)
        (or (string-equal (directory-file-name pre)
                          (directory-file-name canon-path))
            (and (> (length canon-path) (length pre))
                 (string-prefix-p pre canon-path)))))))

(defun eclaw--project-root-for-eclaw-writes ()
  "Return project directory containing `.eclaw', or nil."
  (eclaw--skills-project-root))

(defun eclaw--skill-dir-name-allowed-p (name)
  "Non-nil when NAME is a single safe skill directory segment."
  (and name
       (not (string-empty-p name))
       (<= (length name) 64)
       (string-match-p "\\`[A-Za-z0-9_-]+\\'" name)))

(defconst eclaw-notes-filename-timestamp-regexp
  "\\`[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]-"
  "Regexp matching the date-time prefix prepended to notes file names.")

(defun eclaw--notes-relative-path-with-timestamp (relative-path)
  "Return RELATIVE-PATH with `YYYY-MM-DD_HHMMSS-' prefixed to the basename if missing."
  (let* ((dir (file-name-directory relative-path))
         (base (file-name-nondirectory relative-path)))
    (if (string-match-p eclaw-notes-filename-timestamp-regexp base)
        relative-path
      (let ((prefixed (concat (format-time-string "%Y-%m-%d_%H%M%S") "-" base)))
        (if dir (concat dir prefixed) prefixed)))))

(defun eclaw-tool-notes-write-text (relative-path content append-p)
  "Write CONTENT to RELATIVE-PATH under `<root>/notes/'.
Create parent directories when missing.  With non-nil APPEND-P, append to an
existing regular file.  Path must end with `.txt' (any case) and resolve under
`notes/'.  A `YYYY-MM-DD_HHMMSS-' prefix is added to the basename when absent.
Return a status string."
  (let* ((root (eclaw--project-root-for-eclaw-writes))
         (rel (eclaw--notes-relative-path-with-timestamp
               (string-trim (or relative-path ""))))
         (text (or content "")))
    (cond
     ((null root)
      "Error: notes_write_text requires a `.eclaw' project root from `default-directory'.")
     ((string-empty-p rel)
      "Error: notes_write_text requires non-empty relative_path under notes/.")
     ((not (string-match-p "\\.[tT][xX][tT]\\'" rel))
      "Error: notes_write_text only allows paths ending in `.txt'.")
     ((string-prefix-p "/" rel)
      "Error: notes_write_text relative_path must not be absolute.")
     (t
      (let* ((root-real (eclaw--canonical-path root))
             (notes-dir (eclaw--canonical-path (expand-file-name "notes" root)))
             (target (eclaw--canonical-path (expand-file-name rel notes-dir))))
        (cond
         ((or (null root-real) (null notes-dir) (null target))
          "Error: could not resolve notes path.")
         ((not (eclaw--canonical-under-directory-p notes-dir root-real))
          "Error: `notes' resolves outside the project root.")
         ((not (eclaw--canonical-under-directory-p target notes-dir))
          "Error: target path escapes the project `notes/` directory.")
         ((and (file-exists-p target) (not (file-regular-p target)))
          "Error: notes target exists but is not a regular file.")
         (t
          (condition-case err
              (progn
                (make-directory (file-name-directory target) 'parents)
                (with-temp-buffer
                  (set-buffer-file-coding-system 'utf-8-unix)
                  (when (and append-p (file-regular-p target))
                    (insert-file-contents-literally target))
                  (insert text)
                  (write-region (point-min) (point-max) target nil 'nomessage))
                (eclaw-debug-message "eclaw: notes_write_text %s `%s`"
                         (if append-p "appended to" "wrote") target)
                (format "Notes %s `%s`."
                        (if append-p "appended to" "saved")
                        rel))
            (error (format "Error writing notes file %S: %S" target err))))))))))

(defun eclaw-tool-skill-write (skill-dir content)
  "Create or replace `.eclaw/skills/<skill-dir>/SKILL.md' with CONTENT (UTF-8).
Return a status string."
  (let* ((root (eclaw--project-root-for-eclaw-writes))
         (text (or content "")))
    (cond
     ((null root)
      "Error: skill_write requires a `.eclaw' project root from `default-directory'.")
     ((not (eclaw--skill-dir-name-allowed-p skill-dir))
      "Error: skill_write skill_dir must be 1–64 chars [A-Za-z0-9_-] only.")
     (t
      (let* ((root-real (eclaw--canonical-path root))
             (dot-eclaw (eclaw--canonical-path (expand-file-name ".eclaw" root)))
             (skills-dir (eclaw--canonical-path
                          (expand-file-name "skills" (expand-file-name ".eclaw" root))))
             (skill-subdir (eclaw--canonical-path
                            (expand-file-name skill-dir skills-dir)))
             (target (eclaw--canonical-path
                      (expand-file-name "SKILL.md" skill-subdir))))
        (cond
         ((or (null root-real) (null dot-eclaw) (null skills-dir)
              (null skill-subdir) (null target))
          "Error: could not resolve skill path.")
         ((not (eclaw--canonical-under-directory-p dot-eclaw root-real))
          "Error: `.eclaw' resolves outside the project root.")
         ((not (eclaw--canonical-under-directory-p skills-dir dot-eclaw))
          "Error: `.eclaw/skills' resolves outside `.eclaw'.")
         ((not (eclaw--canonical-under-directory-p skill-subdir skills-dir))
          "Error: skill directory resolves outside `.eclaw/skills/'.")
         ((not (eclaw--canonical-under-directory-p target skill-subdir))
          "Error: SKILL.md path escapes the skill directory.")
         ((not (string-equal (file-name-nondirectory target) "SKILL.md"))
          "Error: skill_write only writes SKILL.md.")
         ((and (file-exists-p target) (not (file-regular-p target)))
          "Error: SKILL.md exists but is not a regular file.")
         (t
          (condition-case err
              (progn
                (make-directory skill-subdir 'parents)
                (with-temp-buffer
                  (set-buffer-file-coding-system 'utf-8-unix)
                  (insert text)
                  (write-region (point-min) (point-max) target nil 'nomessage))
                (eclaw--invalidate-skills-cache)
                (eclaw-debug-message "eclaw: skill_write updated %s" target)
                (format "Skill saved as `.eclaw/skills/%s/SKILL.md`." skill-dir))
            (error (format "Error writing skill file %S: %S" target err))))))))))

(defun eclaw--json-truthy-p (value)
  "Non-nil when VALUE is not nil and not JSON false (`json-read' marker)."
  (and value (not (eq value :json-false))))

(defun eclaw--truncate-string (string max-len)
  "Return STRING truncated to MAX-LEN characters, with an ellipsis suffix."
  (if (<= (length string) max-len)
      string
    (concat (substring string 0 max-len) "…")))

(defun eclaw--registry-tool-names-sorted ()
  "Return sorted tool names in `eclaw--tool-registry'."
  (let (keys)
    (maphash (lambda (k _) (push k keys)) eclaw--tool-registry)
    (sort keys #'string<)))

(defun eclaw--register-tool (name description parameters-schema handler)
  "Register a tool NAME (string) for the API and for dispatch.
PARAMETERS-SCHEMA is the JSON Schema `parameters' object (type object,
properties, required).  HANDLER is `(lambda (args) ...)' with ARGS an
alist of symbol keys from parsed tool arguments."
  (puthash name
           (list :description description
                 :parameters parameters-schema
                 :handler handler)
           eclaw--tool-registry))

(defun eclaw--deftool-params-to-schema (params)
  "Turn PARAMS from `eclaw-deftool' into a JSON Schema parameters alist.
Each element is (SYM TYPE-KEYWORD DESCRIPTION [:optional]).
TYPE-KEYWORD is one of :string, :integer, :number, :boolean, :array, :object.
When the fourth element is `:optional', omit SYM from JSON `required'."
  (let (properties required)
    (dolist (spec params)
      (unless (and (listp spec) (>= (length spec) 3))
        (error "Invalid `eclaw-deftool' parameter spec: %S" spec))
      (let* ((sym (car spec))
             (type-kw (cadr spec))
             (desc (caddr spec))
             (optional-p (and (>= (length spec) 4) (eq (nth 3 spec) :optional)))
             (json-type
              (pcase type-kw
                (:string "string")
                (:integer "integer")
                (:number "number")
                (:boolean "boolean")
                (:array "array")
                (:object "object")
                (_ (error "Unknown `eclaw-deftool' parameter type %S" type-kw)))))
        (push (cons sym `((type . ,json-type) (description . ,desc)))
              properties)
        (unless optional-p
          (push sym required))))
    `((type . "object")
      (properties . ,(nreverse properties))
      (required . ,(apply #'vector (mapcar #'symbol-name (nreverse required)))))))

(defmacro eclaw-deftool (name description params &rest body)
  "Declare a model-invokable tool.
NAME is a symbol (API name is `symbol-name' of NAME).  DESCRIPTION is a
short string for the API.  PARAMS is a list of (SYM TYPE-KEYWORD DESC [:optional]).
TYPE-KEYWORD is :string, :integer, etc.; each SYM is bound in BODY
from the parsed arguments alist passed to the implementation.
Use `:optional' as fourth element to omit the property from JSON `required'.

BODY should return a string (tool result content for the model)."
  (declare (indent 2))
  (unless (stringp description)
    (error "`eclaw-deftool' description must be a string"))
  (let ((bindings
         (mapcar (lambda (spec)
                   (unless (and (consp spec) (symbolp (car spec)))
                     (error "Invalid `eclaw-deftool' parameter: %S" spec))
                   (let ((sym (car spec)))
                     (list sym `(alist-get ',sym args))))
                 params)))
    `(eclaw--register-tool
      ,(symbol-name name)
      ,description
      (eclaw--deftool-params-to-schema ',params)
      (lambda (args)
        (let* ,bindings
          ,@body)))))

(defun eclaw-tool-definitions ()
  "Return the OpenAI-format `tools' list, or nil if tools are disabled or absent.
Replaces the former `eclaw-tool-definitions' variable; set `eclaw-tools-enabled'
to nil for text-only requests."
  (when (and eclaw-tools-enabled (> (hash-table-count eclaw--tool-registry) 0))
    (let (out)
      (dolist (name (eclaw--registry-tool-names-sorted))
        (let* ((info (gethash name eclaw--tool-registry))
               (descr (plist-get info :description))
               (params (plist-get info :parameters)))
          (push `((type . "function")
                  (function . ((name . ,name)
                               (description . ,descr)
                               (parameters . ,params))))
                out)))
      (nreverse out))))

;;; Tool execution

(defun eclaw-tool-read-file (path)
  "Read the file at PATH literally and return its contents as a string.
PATH is expanded with `expand-file-name'.  When `eclaw--path-sensitive-p'
holds, return `eclaw--sensitive-path-msg'.  On other I/O errors, return a
human-readable description instead of signaling."
  (let ((file (expand-file-name path)))
    (if (eclaw--path-sensitive-p file)
        eclaw--sensitive-path-msg
      (condition-case err
          (with-temp-buffer
            (insert-file-contents-literally file)
            (buffer-string))
        (error (format "Error reading file %S: %S" file err))))))

(eclaw-deftool read_file
  "Read the full text of a file from disk."
  ((path :string "File path (absolute or relative to default directory)."))
  (if path
      (progn
        (when (and (not (eclaw--path-sensitive-p path))
                   (eclaw--path-is-project-skill-md-p path))
          (eclaw-debug-message "eclaw: skill file read (model loaded skill): %s"
                   (expand-file-name path)))
        (eclaw-tool-read-file path))
    "Error: read_file requires \"path\" in arguments."))

(defun eclaw-tool-list-directory (path max-entries include-hidden)
  "List up to MAX-ENTRIES entries in directory PATH.
When INCLUDE-HIDDEN is nil, omit dotfiles.  Return a multi-line string
or an error description."
  (let* ((dir (expand-file-name path))
         (cap (if (and max-entries (integerp max-entries) (> max-entries 0))
                  max-entries
                200))
         (show-hidden (eclaw--json-truthy-p include-hidden)))
    (cond
     ((not (file-directory-p dir))
      (format "Error: not a directory %S" dir))
     ((eclaw--path-sensitive-p dir)
      eclaw--sensitive-path-msg)
     (t
      (condition-case err
          (let* ((entries (directory-files dir nil nil t))
                 (entries (seq-remove (lambda (f) (member f '("." ".."))) entries))
                 (entries (if show-hidden
                              entries
                            (seq-remove (lambda (f) (string-prefix-p "." f)) entries)))
                 (filtered
                  (seq-remove (lambda (name)
                                (eclaw--path-sensitive-p (expand-file-name name dir)))
                              entries))
                 (sorted (sort filtered #'string-lessp))
                 (truncated (> (length sorted) cap))
                 (shown (if truncated (seq-take sorted cap) sorted)))
            (concat
             (mapconcat
              (lambda (name)
                (let ((full (expand-file-name name dir)))
                  (format "%s %s"
                          (if (file-directory-p full) "d" "-")
                          name)))
              shown
              "\n")
             (when truncated
               (format "\n[eclaw: listing truncated to %d entr%s]"
                       cap (if (= cap 1) "y" "ies")))))
        (error (format "Error listing directory %S: %S" dir err)))))))

(eclaw-deftool list_directory
  "List files and subdirectories under a path (names + file/dir marker)."
  ((path :string "Directory path (absolute or relative to default directory).")
   (max_entries :integer
                "Maximum entries to return (default 200 when omitted)."
                :optional)
   (include_hidden :boolean
                    "When true, include dotfiles (default false when omitted)."
                    :optional))
  (if path
      (eclaw-tool-list-directory path max_entries include_hidden)
    "Error: list_directory requires \"path\" in arguments."))

(defun eclaw--rg-resolved-program (program)
  "Return absolute path to PROGRAM when executable, otherwise nil."
  (when (and program (not (string-empty-p program)))
    (cond
     ((and (file-name-absolute-p program) (file-executable-p program))
      program)
     ((executable-find program)))))

(defun eclaw--rg-resolve-program ()
  "Return executable for `eclaw-grep-program', trying the alternate grep/rg if needed."
  (or (eclaw--rg-resolved-program eclaw-grep-program)
      (when (string-equal eclaw-grep-program "rg")
        (eclaw--rg-resolved-program "grep"))
      (when (string-equal eclaw-grep-program "grep")
        (eclaw--rg-resolved-program "rg"))))

(defun eclaw--rg-program-basename (program)
  "Return basename of PROGRAM path for backend detection."
  (file-name-nondirectory program))

(defun eclaw--rg-ripgrep-p (program)
  "Non-nil when PROGRAM names ripgrep."
  (string-match-p "\\`rg\\'" (eclaw--rg-program-basename program)))

(defun eclaw--rg-include-ignored-p (include-ignored)
  "Non-nil when ripgrep/grep search should include gitignored paths."
  (cond
   ((eclaw--json-truthy-p include-ignored) t)
   ((eq include-ignored :json-false) nil)
   (t (not eclaw-rg-respect-gitignore))))

(defun eclaw--rg-include-hidden-p (include-hidden)
  "Non-nil when ripgrep should include hidden files and directories."
  (eclaw--json-truthy-p include-hidden))

(defun eclaw--rg-effective-head-limit (head-limit)
  "Return positive head limit from HEAD-LIMIT, default, or hard cap."
  (let ((lim (cond
              ((and head-limit (integerp head-limit) (> head-limit 0))
               head-limit)
              ((and head-limit (integerp head-limit) (= head-limit 0))
               eclaw-rg-max-head-limit)
              (t eclaw-rg-default-head-limit))))
    (min lim eclaw-rg-max-head-limit)))

(defun eclaw--rg-effective-offset (offset)
  "Return non-negative integer offset."
  (if (and offset (integerp offset) (>= offset 0))
      offset
    0))

(defun eclaw--rg-normalize-output-mode (mode)
  "Return normalized output mode symbol for MODE string."
  (let ((m (downcase (or mode "files_with_matches"))))
    (cond
     ((string= m "files_with_matches") 'files_with_matches)
     ((string= m "content") 'content)
     ((string= m "count") 'count)
     (t (error "Invalid output_mode %S (expected files_with_matches, content, or count)"
               mode)))))

(defun eclaw--rg-validate-search-target (path)
  "Return an error string when PATH cannot be searched, otherwise nil."
  (let ((abs (expand-file-name path)))
    (cond
     ((not (or (file-directory-p abs) (file-regular-p abs)))
      (format "Error: not a file or directory %S" abs))
     ((eclaw--path-sensitive-p abs)
      eclaw--sensitive-path-msg)
     (t nil))))

(defun eclaw--rg-validate-directory (path)
  "Return an error string when PATH is not a searchable directory, otherwise nil."
  (let ((abs (expand-file-name path)))
    (cond
     ((not (file-directory-p abs))
      (format "Error: not a directory %S" abs))
     ((eclaw--path-sensitive-p abs)
      eclaw--sensitive-path-msg)
     (t nil))))

(defun eclaw--rg-append-scope-args (args include-hidden include-ignored glob type)
  "Append ripgrep scope flags to ARGS."
  (append args
          (when (eclaw--rg-include-hidden-p include-hidden)
            '("--hidden"))
          (when (eclaw--rg-include-ignored-p include-ignored)
            '("--no-ignore"))
          (when (and glob (not (string-empty-p glob)))
            (list "--glob" glob))
          (when (and type (not (string-empty-p type)))
            (list "--type" type))))

(defun eclaw--rg-run-process (program args)
  "Run PROGRAM with ARGS via `call-process'.
Return (STATUS . OUTPUT-STRING).  STATUS is the process exit code."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil (current-buffer) nil args)))
      (cons status (buffer-substring-no-properties (point-min) (point-max))))))

(defun eclaw--rg-format-results (lines head-limit truncated-p &optional empty-msg)
  "Format LINES with optional truncation marker."
  (concat
   (if lines
       (mapconcat #'identity lines "\n")
     (or empty-msg "(no matches)"))
   (when truncated-p
     (format "\n[eclaw: result limit %d reached]" head-limit))))

(defun eclaw--rg-apply-limit (items offset head-limit)
  "Return (SHOWN TRUNCATED-P) after OFFSET and HEAD-LIMIT on ITEMS."
  (let* ((off (eclaw--rg-effective-offset offset))
         (lim (eclaw--rg-effective-head-limit head-limit))
         (rest (nthcdr (min off (length items)) items))
         (truncated (> (length rest) lim))
         (shown (if truncated (seq-take rest lim) rest)))
    (list shown truncated)))

(defun eclaw--rg-filter-paths (paths)
  "Drop sensitive paths from PATHS."
  (seq-filter (lambda (p) (not (eclaw--path-sensitive-p p))) paths))

(defun eclaw--rg-parse-content-line (line)
  "Parse one grep/rg content LINE into (FILE LINE-NUM CONTENT), or nil."
  (when (and line (not (string-empty-p line)))
    (when (string-match "\\`\\([^:\n]+\\):\\([0-9]+\\):\\(.*\\)\\'" line)
      (list (match-string 1 line)
            (string-to-number (match-string 2 line))
            (match-string 3 line)))))

(defun eclaw--rg-parse-count-line (line)
  "Parse one grep/rg count LINE into (FILE COUNT), or nil."
  (when (and line (not (string-empty-p line)))
    (when (string-match "\\`\\([^:\n]+\\):\\([0-9]+\\)\\'" line)
      (list (match-string 1 line)
            (string-to-number (match-string 2 line))))))

(defun eclaw--rg-filter-content-lines (raw-lines head-limit offset max-line-length)
  "Filter RAW content lines, drop sensitive paths, cap results.
Return (LINES TRUNCATED-P EFFECTIVE-LIMIT)."
  (let* ((lim (eclaw--rg-effective-head-limit head-limit))
         (off (eclaw--rg-effective-offset offset))
         (kept nil)
         (skipped 0)
         (count 0)
         (truncated nil))
    (dolist (line raw-lines)
      (when-let* ((parsed (eclaw--rg-parse-content-line line))
                  (file (expand-file-name (car parsed)))
                  (_ (not (eclaw--path-sensitive-p file))))
        (if (< skipped off)
            (setq skipped (1+ skipped))
          (if (< count lim)
              (let ((ln (cadr parsed))
                    (content (caddr parsed)))
                (push (format "%s:%d:%s"
                              file ln
                              (eclaw--truncate-string content max-line-length))
                      kept)
                (setq count (1+ count)))
            (setq truncated t)))))
    (list (nreverse kept) truncated lim)))

(defun eclaw--rg-filter-path-lines (raw-output head-limit offset)
  "Filter path-only lines, drop sensitive paths, apply offset/limit.
Return (PATHS TRUNCATED-P EFFECTIVE-LIMIT)."
  (let* ((paths (eclaw--rg-filter-paths
                 (mapcar #'expand-file-name (split-string raw-output "\n" t))))
         (limited (eclaw--rg-apply-limit paths offset head-limit)))
    (list (car limited) (cadr limited) (eclaw--rg-effective-head-limit head-limit))))

(defun eclaw--rg-filter-count-lines (raw-output head-limit offset)
  "Filter count lines, drop sensitive paths, apply offset/limit.
Return (LINES TRUNCATED-P EFFECTIVE-LIMIT)."
  (let ((entries nil))
    (dolist (line (split-string raw-output "\n" t))
      (when-let* ((parsed (eclaw--rg-parse-count-line line))
                  (file (expand-file-name (car parsed)))
                  (count (cadr parsed))
                  (_ (not (eclaw--path-sensitive-p file))))
        (push (cons file count) entries)))
    (let* ((limited (eclaw--rg-apply-limit entries offset head-limit))
           (shown (car limited))
           (truncated (cadr limited))
           (lim (eclaw--rg-effective-head-limit head-limit)))
      (list (mapcar (lambda (entry)
                      (format "%s:%d" (car entry) (cdr entry)))
                    shown)
            truncated
            lim))))

(defun eclaw--rg-build-grep-args (program root pattern output-mode multiline-p
                                    case-insensitive-p include-hidden include-ignored
                                    glob type)
  "Return argv for ripgrep or GNU grep content/files/count search."
  (let ((glob-str (or glob ""))
        (type-str (or type "")))
    (cond
     ((eclaw--rg-ripgrep-p program)
      (let ((args (eclaw--rg-append-scope-args
                   (append
                    (pcase output-mode
                      ('files_with_matches '("--files-with-matches"))
                      ('count '("--count"))
                      (_ '("--line-number" "--no-heading")))
                    '("--no-messages")
                    (when (eclaw--json-truthy-p case-insensitive-p) '("-i"))
                    (when (eclaw--json-truthy-p multiline-p)
                      '("-U" "--multiline-dotall")))
                   include-hidden include-ignored glob-str type-str)))
        (append args (list "-e" pattern root))))
     ((string-equal (eclaw--rg-program-basename program) "grep")
      (when (eclaw--json-truthy-p multiline-p)
        (error "multiline search requires ripgrep (rg), not GNU grep"))
      (when (and type-str (not (string-empty-p type-str)))
        (error "type filter requires ripgrep (rg), not GNU grep"))
      (append
       (pcase output-mode
         ('files_with_matches '("-r" "-l" "-I" "--no-messages" "-D" "skip"))
         ('count '("-r" "-c" "-I" "--no-messages" "-D" "skip"))
         (_ '("-r" "-E" "-n" "-H" "-I" "--no-messages" "-D" "skip")))
       (when (eclaw--json-truthy-p case-insensitive-p) '("-i"))
       (when (not (string-empty-p glob-str))
         (list "--include" glob-str))
       (list "-e" pattern root)))
     (t
      (error "Unsupported search program %S" program)))))

(defun eclaw--rg-build-glob-args (program root pattern include-hidden include-ignored)
  "Return argv for ripgrep file listing."
  (unless (eclaw--rg-ripgrep-p program)
    (error "glob_files requires ripgrep (rg), not GNU grep"))
  (append
   (eclaw--rg-append-scope-args
    '("--files" "--no-messages")
    include-hidden include-ignored pattern nil)
   (list root)))

(defun eclaw--rg-file-mtime-or-zero (file)
  "Return modification time of FILE as float, or 0.0 when unavailable."
  (condition-case nil
      (eclaw--file-mtime-float file)
    (error 0.0)))

(defun eclaw--rg-sort-paths-by-mtime (paths)
  "Return PATHS sorted by modification time, newest first."
  (sort (copy-sequence paths)
        (lambda (a b)
          (> (eclaw--rg-file-mtime-or-zero a)
             (eclaw--rg-file-mtime-or-zero b)))))

(defun eclaw--rg-via-process (program root pattern &rest options)
  "Run ripgrep or grep and return a formatted result string.
OPTIONS is a plist with keys :output-mode, :multiline, :case-insensitive,
:include-hidden, :include-ignored, :glob, :type, :head-limit, :offset,
and :max-line-length."
  (let* ((output-mode (eclaw--rg-normalize-output-mode (plist-get options :output-mode)))
         (head-limit (plist-get options :head-limit))
         (offset (plist-get options :offset))
         (max-line-length
          (let ((lim (plist-get options :max-line-length)))
            (if (and lim (integerp lim) (> lim 0))
                lim
              500)))
         (args (eclaw--rg-build-grep-args
                program root pattern output-mode
                (plist-get options :multiline)
                (plist-get options :case-insensitive)
                (plist-get options :include-hidden)
                (plist-get options :include-ignored)
                (plist-get options :glob)
                (plist-get options :type))))
    (if-let ((exe (or program (eclaw--rg-resolve-program))))
        (let* ((proc (eclaw--rg-run-process exe args))
               (status (car proc))
               (output (cdr proc)))
          (if (member status '(0 1))
              (pcase output-mode
                ('content
                 (let ((filtered (eclaw--rg-filter-content-lines
                                   (split-string output "\n" t)
                                   head-limit offset max-line-length)))
                   (eclaw--rg-format-results (nth 0 filtered) (nth 2 filtered) (nth 1 filtered))))
                ('files_with_matches
                 (let ((filtered (eclaw--rg-filter-path-lines
                                   output head-limit offset)))
                   (eclaw--rg-format-results (nth 0 filtered) (nth 2 filtered) (nth 1 filtered))))
                ('count
                 (let ((filtered (eclaw--rg-filter-count-lines
                                   output head-limit offset)))
                   (eclaw--rg-format-results (nth 0 filtered) (nth 2 filtered) (nth 1 filtered)))))
            (format "Error: %s exited with status %s"
                    (eclaw--rg-program-basename exe) status)))
      (format "Error: ripgrep/grep not found (see `eclaw-grep-program')"))))

(defun eclaw--rg-glob-via-process (root pattern head-limit offset
                                   include-hidden include-ignored)
  "List files under ROOT matching glob PATTERN; return formatted string."
  (if-let ((exe (eclaw--rg-resolved-program "rg")))
      (let* ((args (eclaw--rg-build-glob-args exe root pattern
                                              include-hidden include-ignored))
             (proc (eclaw--rg-run-process exe args))
             (status (car proc))
             (output (cdr proc)))
        (if (member status '(0 1))
            (let* ((paths (eclaw--rg-sort-paths-by-mtime
                           (eclaw--rg-filter-paths
                            (mapcar #'expand-file-name
                                    (split-string output "\n" t)))))
                   (limited (eclaw--rg-apply-limit paths offset head-limit)))
              (eclaw--rg-format-results (car limited)
                                        (eclaw--rg-effective-head-limit head-limit)
                                        (cadr limited)
                                        "(no files)"))
          (format "Error: rg exited with status %s" status)))
    (format "Error: ripgrep (rg) not found (glob_files requires rg)")))

(defun eclaw-tool-grep-files (path root pattern glob type output-mode multiline
                            case-insensitive head-limit offset include-hidden
                            include-ignored max-line-length)
  "Search under PATH (or ROOT alias) for regex PATTERN; return capped results."
  (let* ((search-path (or path root default-directory))
         (pat (or pattern "")))
    (cond
     ((string-empty-p pat)
      "Error: grep_files requires non-empty pattern (ripgrep regex).")
     ((> (length pat) eclaw-rg-max-pattern-length)
      (format "Error: grep_files pattern exceeds max length (%d)"
              eclaw-rg-max-pattern-length))
     ((eclaw--rg-validate-search-target search-path))
     (t
      (condition-case err
          (eclaw--rg-via-process
           (eclaw--rg-resolve-program)
           (expand-file-name search-path)
           pat
           :output-mode output-mode
           :multiline multiline
           :case-insensitive case-insensitive
           :include-hidden include-hidden
           :include-ignored include-ignored
           :glob glob
           :type type
           :head-limit head-limit
           :offset offset
           :max-line-length max-line-length)
        (error (format "Error during grep_files under %S: %S"
                       (expand-file-name search-path) err)))))))

(defun eclaw-tool-glob-files (path pattern head-limit offset include-hidden include-ignored)
  "Find files under PATH matching glob PATTERN; return capped paths."
  (let* ((root (expand-file-name (or path default-directory)))
         (glob (or pattern "")))
    (cond
     ((string-empty-p glob)
      "Error: glob_files requires non-empty pattern (glob syntax).")
     ((eclaw--rg-validate-directory root))
     (t
      (condition-case err
          (eclaw--rg-glob-via-process root glob head-limit offset
                                      include-hidden include-ignored)
        (error (format "Error during glob_files under %S: %S" root err)))))))

(eclaw-deftool grep_files
  "Search file contents under a path using ripgrep regex syntax."
  ((path :string
         "File or directory to search (absolute or relative). Defaults to default-directory."
         :optional)
   (root :string "Deprecated alias for path." :optional)
   (pattern :string "Regular expression (ripgrep syntax).")
   (glob :string "Optional file glob filter, e.g. **/*.el." :optional)
   (type :string "Optional ripgrep file type, e.g. el, py, rust." :optional)
   (output_mode :string
                "files_with_matches (default), content, or count."
                :optional)
   (multiline :boolean "When true, patterns may span line boundaries." :optional)
   (case_insensitive :boolean "When true, case-insensitive search." :optional)
   (head_limit :integer
               "Max entries after filtering (default 250 when omitted)."
               :optional)
   (offset :integer "Skip first N entries after filtering." :optional)
   (include_hidden :boolean "When true, include hidden files and directories." :optional)
   (include_ignored :boolean "When true, search gitignored paths." :optional)
   (max_line_length :integer
                    "Truncate matching lines in content mode (default 500)."
                    :optional))
  (if pattern
      (eclaw-tool-grep-files path root pattern glob type output_mode multiline
                             case_insensitive head_limit offset include_hidden
                             include_ignored max_line_length)
    "Error: grep_files requires \"pattern\" in arguments."))

(eclaw-deftool glob_files
  "Find files under a directory whose paths match a glob pattern."
  ((path :string
         "Directory root (absolute or relative). Defaults to default-directory."
         :optional)
   (pattern :string "Glob pattern, e.g. **/*.el or **/SKILL.md.")
   (head_limit :integer
               "Max paths after filtering (default 250 when omitted)."
               :optional)
   (offset :integer "Skip first N paths after filtering." :optional)
   (include_hidden :boolean "When true, include hidden files and directories." :optional)
   (include_ignored :boolean "When true, include gitignored paths." :optional))
  (if pattern
      (eclaw-tool-glob-files path pattern head_limit offset include_hidden include_ignored)
    "Error: glob_files requires \"pattern\" in arguments."))

(eclaw-deftool notes_write_text
  "Write a `.txt` under the project `notes/` directory (create or append).
Basename is prefixed with `YYYY-MM-DD_HHMMSS-` when that prefix is not already present."
  ((relative_path :string
                  "Path relative to notes/ (not absolute); must end with .txt. A YYYY-MM-DD_HHMMSS- prefix is added to the basename automatically.")
   (content :string "Full file body to write (UTF-8).")
   (append :boolean
           "When true, append to an existing file instead of overwriting."
           :optional))
  (if relative_path
      (if content
          (eclaw-tool-notes-write-text relative_path content (eclaw--json-truthy-p append))
        "Error: notes_write_text requires \"content\" in arguments.")
    "Error: notes_write_text requires \"relative_path\" in arguments."))

(eclaw-deftool skill_write
  "Write `.eclaw/skills/<skill_dir>/SKILL.md` (full body; UTF-8)."
  ((skill_dir :string
              "Single directory name under .eclaw/skills/ ([A-Za-z0-9_-], max 64 chars).")
   (content :string "Full SKILL.md body (UTF-8), including optional YAML front matter."))
  (if skill_dir
      (if content
          (eclaw-tool-skill-write skill_dir content)
        "Error: skill_write requires \"content\" in arguments.")
    "Error: skill_write requires \"skill_dir\" in arguments."))

(defun eclaw--dispatch-one-tool-call (tool-call)
  "Execute the TOOL-CALL alist from the API; return the tool result string.
TOOL-CALL follows the API tool-call shape (`function.name', `function.arguments'
JSON).  Dispatches via `eclaw--tool-registry'; unknown tools yield a short
error string."
  (let* ((fn-spec (alist-get 'function tool-call))
         (name (alist-get 'name fn-spec))
         (args-str (alist-get 'arguments fn-spec))
         (args
          (let ((json-object-type 'alist)
                (json-array-type 'list)
                (json-key-type 'symbol))
            (json-read-from-string args-str))))
    (message
     "eclaw: tool %s%s"
     name
     (let ((preview (string-trim (or args-str ""))))
       (if (or (string-empty-p preview) (string-equal preview "{}"))
           ""
         (let ((max 100))
           (if (> (length preview) max)
               (format " %s…" (substring preview 0 max))
             (format " %s" preview))))))
    (if-let ((info (gethash name eclaw--tool-registry))
             (handler (plist-get info :handler)))
        (funcall handler args)
      (format "Unknown tool: %s" name))))

(defun eclaw--tool-result-messages (tool-calls &optional synth-reason)
  "Return a list of tool message alists, one per element of TOOL-CALLS.
When SYNTH-REASON is non-nil, do not run handlers; use it in the abort text."
  (mapcar
   (lambda (tc)
     (let ((id (alist-get 'id tc)))
       (unless id
         (error "eclaw: tool call missing id"))
       (eclaw-tool-message
        id
        (if synth-reason
            (format "[eclaw aborted: %s]" synth-reason)
          (eclaw--dispatch-one-tool-call tc)))))
   tool-calls))

;;; HTTP transport

(defun eclaw--utf8-unibyte-string (string)
  "Return STRING as unibyte UTF-8 bytes for HTTP headers or body.
Emacs `url' rejects multibyte text in outgoing requests; JSON payloads and
header values (including `getenv' results) are often multibyte even when ASCII."
  (encode-coding-string (or string "") 'utf-8))

(defun eclaw--http-unibyte-headers (headers)
  "Return HEADERS alist with each value encoded as unibyte UTF-8."
  (mapcar (lambda (pair)
            (cons (car pair)
                  (eclaw--utf8-unibyte-string (cdr pair))))
          headers))

(defun eclaw--assert-http-unibyte-p (body &optional headers)
  "Signal an internal error when BODY or header values are not unibyte.
Guards against regressions: all outgoing HTTP must go through `eclaw--http-post'."
  (unless (and body (not (multibyte-string-p body)))
    (error "eclaw internal error: HTTP body must be unibyte UTF-8"))
  (dolist (pair headers)
    (unless (and (cdr pair) (not (multibyte-string-p (cdr pair))))
      (error "eclaw internal error: HTTP header %S must be unibyte UTF-8"
             (car pair)))))

(defun eclaw--http-post (url headers body)
  "POST BODY (any string) to URL with HEADERS alist; return response buffer.
This is the only function that sets `url-request-method', `url-request-data',
and `url-request-extra-headers'.  Headers and body are encoded as unibyte UTF-8
before calling `url-retrieve-synchronously'.  See `docs/http-transport.md'."
  (let* ((headers (eclaw--http-unibyte-headers headers))
         (body-bytes (eclaw--utf8-unibyte-string body))
         (url-request-method "POST")
         (url-request-extra-headers headers)
         (url-request-data body-bytes))
    (eclaw--assert-http-unibyte-p body-bytes headers)
    (url-retrieve-synchronously url)))

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

(defun eclaw-post-completion-request (payload)
  "POST PAYLOAD to OpenRouter chat completions; return parsed JSON alist.
Announces progress in the echo area, then blocks until
`url-retrieve-synchronously' completes.  Signals on HTTP or API errors via
`eclaw-get-response'.  Does not mutate conversation state or log."
  (when eclaw-debug
    (eclaw-debug-message "eclaw: contacting OpenRouter…")
    (redisplay t))
  (eclaw-get-response
   (eclaw--http-post
    "https://openrouter.ai/api/v1/chat/completions"
    `(("Authorization" . ,(concat "Bearer " (eclaw-get-api-key)))
      ("Content-Type" . "application/json; charset=utf-8"))
    (json-encode payload))))

(defun eclaw--response-error-body (buffer)
  "Return the UTF-8-decoded HTTP body of BUFFER after the headers.
Assumes `url-http-end-of-headers' is set in BUFFER (from `url')."
  (with-current-buffer buffer
    (goto-char url-http-end-of-headers)
    (set-buffer-multibyte t)
    (decode-coding-region (point) (point-max) 'utf-8)
    (buffer-substring-no-properties (point) (point-max))))

(defun eclaw-get-response (buffer)
  "Parse the JSON chat completion object from BUFFER, then kill BUFFER.
Signals an error if BUFFER is nil (failed retrieve), if HTTP status is
outside 2xx, or if the parsed JSON includes a top-level `error' entry.
On success returns an alist with symbol keys (`json-read' settings)."
  (unless buffer
    ;; `url-retrieve-synchronously' returns nil when the retrieve failed.
    (error "eclaw: request failed before a response was available"))
  (with-current-buffer buffer
    (let ((status (or url-http-response-status -1)))
      (unless (and (integerp status) (<= 200 status 299))
        (let ((body (eclaw--response-error-body buffer)))
          (kill-buffer buffer)
          (error "eclaw: HTTP %s from OpenRouter:\n%s"
                 status
                 (if (> (length body) 500)
                     (concat (substring body 0 500) "…")
                   body)))))
    (goto-char url-http-end-of-headers)
    (set-buffer-multibyte t)
    (decode-coding-region (point) (point-max) 'utf-8)
    (let* ((json-object-type 'alist)
           (json-array-type 'list)
           (json-key-type 'symbol)
           (response (json-read)))
      (kill-buffer buffer)
      (when-let ((err (alist-get 'error response)))
        (error "eclaw: OpenRouter error in JSON body: %S" err))
      response)))

(defun eclaw-get-first-choice (response)
  "From parsed completion RESPONSE, return `choices[0]' alist or nil.
RESPONSE is the alist returned by `eclaw-get-response'."
  (let ((choices (alist-get 'choices response)))
    (when choices
      (elt choices 0))))

(defun eclaw-get-message (response)
  "From RESPONSE, return the nested `message' alist inside first choice.
This is the assistant message object (text and/or `tool_calls')."
  (alist-get 'message (eclaw-get-first-choice response)))

(defun eclaw-get-content (response)
  "From RESPONSE, return the assistant's string `content', or nil.
Nil is normal when the model issued `tool_calls' instead of text.
When `content' is empty, fall back to `reasoning' if present."
  (let ((msg (eclaw-get-message response)))
    (or (alist-get 'content msg)
        (alist-get 'reasoning msg))))

(defun eclaw-get-tool-calls (response)
  "From RESPONSE, return the assistant's `tool_calls' list or nil.
Each element follows the API tool-call shape (id, type, function, ...)."
  (alist-get 'tool_calls (eclaw-get-message response)))

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
conversation is left in a valid shape for the next user message.

The user turn is appended to `eclaw-conversation' before the first
request so history matches what was sent even when a request fails.
Each HTTP exchange is logged."
  (setq eclaw-conversation
        (nconc eclaw-conversation (list (eclaw-user-message prompt))))
  (let ((messages (eclaw-build-messages))
        (total-tokens 0)
        (completions 0))
    (catch 'eclaw-chat-done
      (while t
        (when (>= completions eclaw-max-completions-per-prompt)
          (let ((msg (concat "[eclaw: stopped — max completions per prompt ("
                             (number-to-string eclaw-max-completions-per-prompt)
                             ") reached]")))
            (message "eclaw: %s" msg)
            (setq eclaw-conversation
                  (nconc eclaw-conversation
                         (list (eclaw-assistant-message msg))))
            (throw 'eclaw-chat-done msg)))
        (setq completions (1+ completions))
        (let* ((payload (eclaw-build-chat-payload messages))
               (response (eclaw-post-completion-request payload))
               (usage (alist-get 'usage response)))
          (eclaw-log payload response)
          (when usage (eclaw-report-usage usage))
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
                      (message "eclaw: %s" note)
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
                  (message "eclaw: token limit exceeded for this prompt"))
                (eclaw-append-assistant-reply content)
                (throw 'eclaw-chat-done content)))))))))

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
   `((timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
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
  (unless eclaw--session-started
    (setq eclaw--session-started (current-time))
    (setq eclaw--session-project (expand-file-name default-directory)))
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
                (message "eclaw: conversation saved to %s" path)
              (user-error "Archive produced no file")))
        (error
         (user-error "Archive failed: %s" (error-message-string err))))
    (user-error "No conversation to save")))

(defun eclaw--list-conversation-files ()
  "Return archive `.md' files sorted newest first."
  (let ((dir (expand-file-name eclaw-conversation-archive-dir)))
    (when (file-directory-p dir)
      (sort
       (directory-files dir nil "\\`[^.].*\\.md\\'")
       (lambda (a b)
         (> (file-attribute-modification-time (file-attributes (expand-file-name a dir)))
            (file-attribute-modification-time (file-attributes (expand-file-name b dir)))))))))

(defun eclaw--conversation-file-label (file)
  "Return a completion label for archive FILE."
  (let* ((full (expand-file-name file eclaw-conversation-archive-dir))
         (mtime (file-attribute-modification-time (file-attributes full)))
         (stamp (when mtime (format-time-string "%Y-%m-%d %H:%M" mtime))))
    (if stamp
        (format "%s  %s" stamp (file-name-nondirectory file))
      (file-name-nondirectory file))))

(defun eclaw-open-conversation (&optional file)
  "Open a saved conversation archive in a read-only markdown buffer."
  (interactive
   (let* ((dir (expand-file-name eclaw-conversation-archive-dir))
          (files (eclaw--list-conversation-files))
          (candidates
           (mapcar (lambda (f)
                     (cons (eclaw--conversation-file-label f) f))
                   files)))
     (unless files
       (user-error "No conversation archives in %s" dir))
     (list (completing-read "Conversation: " candidates nil t))))
  (let ((path (expand-file-name file eclaw-conversation-archive-dir)))
    (unless (file-readable-p path)
      (user-error "Conversation file not readable: %s" path))
    (find-file-read-only path)
    (eclaw--eclaw-buffer-setup)))

(defun eclaw-list-conversations ()
  "Open `eclaw-conversation-archive-dir' in Dired."
  (interactive)
  (let ((dir (expand-file-name eclaw-conversation-archive-dir)))
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

(defcustom eclaw-agent-log-file
  (expand-file-name "eclaw-log.jsonl" (expand-file-name eclaw-data-dir))
  "File path for JSONL log lines written by `eclaw-append-json-log'."
  :type 'file
  :group 'eclaw)

(defun eclaw-append-json-log (data)
  "Append DATA, JSON-encoded, as one line to `eclaw-agent-log-file'."
  (make-directory (file-name-directory (expand-file-name eclaw-agent-log-file)) t)
  (with-temp-buffer
    (insert
     (json-encode data))
    ;; JSONL separator
    (goto-char (point-max))
    (insert "\n")
    (append-to-file
     (point-min)
     (point-max)
     eclaw-agent-log-file)))

(provide 'eclaw)
;;; eclaw.el ends here
