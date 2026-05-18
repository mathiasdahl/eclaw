;;; eclaw.el --- Experimental AI agent

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
;; eclaw is a small, synchronous chat client for the OpenRouter chat
;; completions API (`https://openrouter.ai/api/v1/chat/completions').
;; It maintains one global conversation as a list of request/response
;; messages and optionally advertises filesystem tools (`read_file',
;; `list_directory', `grep_files') guarded by a sensitive-path policy,
;; plus narrow writes (`notes_write_text', `skill_write') limited to
;; `notes/*.txt' and `.eclaw/skills/<name>/SKILL.md' under the `.eclaw' root.
;;
;; Layers (all in this file; transport is not yet split out):
;;
;; - Configuration: API key, model id, system prompt; tools via `eclaw-deftool';
;;   sensitive-path defaults via `eclaw-sensitive-path-prefixes' /
;;   `eclaw-sensitive-path-files'.
;; - Message builders: alists shaped like OpenAI chat messages; serialized
;;   with `json-encode' (symbol keys, vectors for `messages' array).
;; - HTTP: `url-retrieve-synchronously' plus strict parsing in
;;   `eclaw-get-response' (status check, JSON `error' field).
;; - Orchestration: `eclaw-chat' loops completions until the assistant returns
;;   without `tool_calls', or a cap is reached (`eclaw-max-completions-per-prompt',
;;   `eclaw-max-tokens-per-prompt').  Each assistant message may request multiple
;;   tools; every call is executed and a matching `role: tool' row is appended.
;; - UI: `eclaw-agent-chat' appends to buffer `*eclaw*'; logging writes
;;   JSON lines to `eclaw-agent-log-file'.
;;
;; Conversation state (`eclaw-conversation') stores only user, assistant,
;; and tool messages from prior turns—not a second copy of the system
;; message.  Each request prepends a fresh system message via
;; `eclaw-system-message'.
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
   "You are eclaw, an Emacs-native AI coding assistant. "
   "You help users write, understand, debug, and refactor code inside Emacs. "
   "Be concise, technically accurate, and practical. "
   "Prefer clear explanations and incremental changes.\n\n"
   "When the user wants durable notes, use `notes_write_text' to create or update "
   "only `.txt' files under the project's `notes/' directory (paths are relative to "
   "`notes/`). When guidance should persist as reusable agent instructions, use "
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

(defun eclaw--skills-signature-for-directory (skills-dir)
  "Return a string that changes when any `SKILL.md' under SKILLS-DIR changes.
If SKILLS-DIR is missing or not a directory, return an empty string."
  (if (not (file-directory-p skills-dir))
      ""
    (let (parts)
      (dolist (entry (directory-files skills-dir nil "^[^.]" t))
        (let* ((sub (expand-file-name entry skills-dir))
               (md (expand-file-name "SKILL.md" sub)))
          (when (and (file-directory-p sub) (file-exists-p md))
            (push (format "%s:%f" md (eclaw--file-mtime-float md)) parts))))
      (mapconcat #'identity (sort parts #'string<) "|"))))

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

(defun eclaw--skills-collect-from-directory (skills-dir)
  "Return sorted list of skill plists for subdirs of SKILLS-DIR that have SKILL.md."
  (let (out)
    (dolist (entry (directory-files skills-dir nil "^[^.]" t))
      (let* ((sub (expand-file-name entry skills-dir))
             (md (expand-file-name "SKILL.md" sub)))
        (when (and (file-directory-p sub) (file-exists-p md))
          (condition-case err
              (push (eclaw--parse-skill-md md entry) out)
            (error (message "eclaw: skipping skill %S: %S" md err))))))
    (sort out (lambda (a b)
                (string-lessp (plist-get a :name) (plist-get b :name))))))

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
             (sig (eclaw--skills-signature-for-directory skills-dir))
             (cached eclaw--skills-cache))
        (if (and cached
                 (equal root (plist-get cached :root))
                 (equal sig (plist-get cached :signature)))
            (plist-get cached :skills)
            (let* ((skills (if (string-empty-p sig)
                             nil
                           (eclaw--skills-collect-from-directory skills-dir)))
                 (plist (list :root root :signature sig :skills skills)))
            (setq eclaw--skills-cache plist)
            (message
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

(defvar eclaw-conversation nil
  "List of prior chat messages for the active session, excluding system.
Each element is an alist: user (`role' user, `content'), assistant
(`role' assistant, `content' and/or `tool_calls' as returned by the
API), or tool (`role' tool, `tool_call_id', `content').  Mutated by
`eclaw-chat', `eclaw-update-conversation', and `eclaw-reset-conversation'.")

(defun eclaw-reset-conversation ()
  "Clear `eclaw-conversation' and confirm in the echo area."
  (interactive)
  (setq eclaw-conversation nil)
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

(defun eclaw-build-messages (prompt)
  "Build the message list for a new user PROMPT.
Result is [system] + `eclaw-conversation' + [user PROMPT] as a flat list
suitable for `eclaw--chat-request-payload'."
  (append
   (list (eclaw-system-message))
   eclaw-conversation
   (list (eclaw-user-message prompt))))

(defun eclaw-build-messages-continuation ()
  "Build the message list after a tool result was appended to history.
Returns a list whose `cdr' is exactly `eclaw-conversation' (already
including the latest user, assistant `tool_calls', and tool messages)
and whose `car' is the current system message."
  (cons (eclaw-system-message) eclaw-conversation))

;;; Tools (registry and `eclaw-deftool')

(defvar eclaw--tool-registry (make-hash-table :test 'equal)
  "Maps tool name string to plist (:description :parameters :handler).
Populated by `eclaw-deftool'.")

(defvar eclaw-tools-enabled t
  "When non-nil, include registered tools in outgoing chat requests.
When nil, behave like text-only completions regardless of registry contents.")

(defgroup eclaw nil
  "Emacs-native OpenRouter chat agent."
  :group 'external)

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

(defvar eclaw-grep-max-file-bytes (* 2 1024 1024)
  "Skip files larger than this many bytes in `eclaw-tool-grep-files'.")

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

(defun eclaw-tool-notes-write-text (relative-path content append-p)
  "Write CONTENT to RELATIVE-PATH under `<root>/notes/'.
Create parent directories when missing.  With non-nil APPEND-P, append to an
existing regular file.  Path must end with `.txt' (any case) and resolve under
`notes/'.  Return a status string."
  (let* ((root (eclaw--project-root-for-eclaw-writes))
         (rel (string-trim (or relative-path "")))
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
                (message "eclaw: notes_write_text %s `%s`"
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
                (message "eclaw: skill_write updated %s" target)
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

;;; HTTP request construction and transport

(defun eclaw--chat-request-payload (messages)
  "Return the JSON-serializable request alist for message list MESSAGES.
MESSAGES must be a list of message alists; it is stored under key `messages'
as a vector.  Adds `tools' when `eclaw-tool-definitions' returns non-nil."
  (let ((base `((model . ,eclaw-model)
               (messages . ,(vconcat messages))))
        (tools (eclaw-tool-definitions)))
    (if tools
        (append base `((tools . ,tools)))
      base)))

(defun eclaw--post-chat-completion (request-payload)
  "POST REQUEST-PAYLOAD to OpenRouter and return the parsed JSON alist.
Announces progress in the echo area, then blocks until
`url-retrieve-synchronously' completes.  Delegates body handling to
`eclaw-get-response'."
  (message "eclaw: contacting OpenRouter…")
  (redisplay t)
  (let ((url-request-method "POST")
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer " (eclaw-get-api-key)))
           ("Content-Type" . "application/json")))
        (url-request-data (json-encode request-payload)))
    (eclaw-get-response
     (url-retrieve-synchronously
      "https://openrouter.ai/api/v1/chat/completions"))))

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
          (message "eclaw: skill file read (model loaded skill): %s"
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

(defun eclaw-tool-grep-files (root pattern glob max-matches max-files-scanned max-line-length)
  "Search files under ROOT for a literal PATTERN; return capped matches.
GLOB filters basenames with shell wildcards (empty means all).  Skip paths
matching `eclaw--path-sensitive-p' and files larger than
`eclaw-grep-max-file-bytes'."
  (let* ((root-abs (expand-file-name root))
         (pat (or pattern ""))
         (glob-str (or glob ""))
         (lim-m (if (and max-matches (integerp max-matches) (> max-matches 0))
                    max-matches
                  100))
         (lim-f (if (and max-files-scanned (integerp max-files-scanned)
                         (> max-files-scanned 0))
                    max-files-scanned
                  5000))
         (lim-l (if (and max-line-length (integerp max-line-length) (> max-line-length 0))
                    max-line-length
                  500))
         (regexp (regexp-quote pat))
         (glob-re (unless (string-empty-p glob-str)
                    (wildcard-to-regexp glob-str))))
    (cond
     ((string-empty-p pat)
      "Error: grep_files requires non-empty pattern (literal substring).")
     ((not (file-directory-p root-abs))
      (format "Error: not a directory %S" root-abs))
     ((eclaw--path-sensitive-p root-abs)
      eclaw--sensitive-path-msg)
     (t
      (condition-case err
          (let ((match-lines nil)
                (match-count 0)
                (scan-count 0)
                (truncated-files nil)
                (truncated-matches nil))
            (catch 'eclaw-grep-done
              (dolist (file (directory-files-recursively root-abs "." nil t nil))
                (when (>= scan-count lim-f)
                  (setq truncated-files t)
                  (throw 'eclaw-grep-done nil))
                (setq scan-count (1+ scan-count))
                (when (and (file-regular-p file)
                           (not (eclaw--path-sensitive-p file))
                           (or (null glob-re)
                               (string-match-p glob-re (file-name-nondirectory file))))
                  (let* ((attrs (file-attributes file))
                         (size (and attrs
                                    (if (fboundp 'file-attribute-size)
                                        (file-attribute-size attrs)
                                      (nth 7 attrs)))))
                    (when (and size (<= size eclaw-grep-max-file-bytes))
                      (condition-case nil
                          (with-temp-buffer
                            (insert-file-contents-literally file)
                            (goto-char (point-min))
                            (while (and (< match-count lim-m) (not (eobp)))
                              (let* ((ln (line-number-at-pos))
                                     (beg (line-beginning-position))
                                     (end (line-end-position))
                                     (line (buffer-substring-no-properties beg end)))
                                (forward-line 1)
                                (when (string-match-p regexp line)
                                  (setq match-count (1+ match-count))
                                  (push (format "%s:%d:%s"
                                                file ln
                                                (eclaw--truncate-string line lim-l))
                                        match-lines)
                                  (when (>= match-count lim-m)
                                    (setq truncated-matches t)
                                    (throw 'eclaw-grep-done nil))))))
                        (error nil)))))))
            (concat
             (if match-lines
                 (mapconcat #'identity (nreverse match-lines) "\n")
               "(no matches)")
             (concat
              (when truncated-matches
                (format "\n[eclaw: match limit %d reached]" lim-m))
              (when truncated-files
                (format "\n[eclaw: file scan limit %d reached]" lim-f)))))
        (error (format "Error during grep_files under %S: %S" root-abs err)))))))

(eclaw-deftool grep_files
  "Search text files under a directory for a literal substring (not a regexp)."
  ((root :string "Directory root to search (absolute or relative).")
   (pattern :string "Literal substring to search for.")
   (glob :string
         "Optional basename glob such as *.el; empty string means all files."
         :optional)
   (max_matches :integer
                "Stop after this many matching lines (default 100 when omitted)."
                :optional)
   (max_files_scanned :integer
                      "Stop after examining this many files (default 5000 when omitted)."
                      :optional)
   (max_line_length :integer
                    "Truncate printed lines to this length (default 500 when omitted)."
                    :optional))
  (if root
      (if pattern
          (eclaw-tool-grep-files root pattern glob max_matches max_files_scanned max_line_length)
        "Error: grep_files requires \"pattern\" in arguments.")
    "Error: grep_files requires \"root\" in arguments."))

(eclaw-deftool notes_write_text
  "Write a `.txt` under the project `notes/` directory (create or append)."
  ((relative_path :string
                  "Path relative to notes/ (not absolute); must end with .txt.")
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

Otherwise, for a reply without tools, behavior matches
`eclaw-update-conversation'.  Each HTTP exchange is logged."
  (let ((messages (eclaw-build-messages prompt))
        (total-tokens 0)
        (completions 0)
        (user-appended nil))
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
        (let* ((payload (eclaw--chat-request-payload messages))
               (response (eclaw--post-chat-completion payload))
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
                  (if user-appended
                      (setq eclaw-conversation
                            (nconc eclaw-conversation
                                   (cons assistant-msg
                                         (eclaw--tool-result-messages
                                          tool-calls synth-reason))))
                    (setq eclaw-conversation
                          (nconc eclaw-conversation
                                 (nconc (list (eclaw-user-message prompt)
                                              assistant-msg)
                                        (eclaw--tool-result-messages
                                         tool-calls synth-reason))))
                    (setq user-appended t))
                  (when over-tokens
                    (let ((note (concat "[eclaw: turn stopped — "
                                        synth-reason "]")))
                      (message "eclaw: %s" note)
                      (setq eclaw-conversation
                            (nconc eclaw-conversation
                                   (list (eclaw-assistant-message note))))
                      (throw 'eclaw-chat-done note)))
                  (setq messages (eclaw-build-messages-continuation)))
              (let ((content (or (eclaw-get-content response) "")))
                (when over-tokens
                  (setq content
                        (concat content
                                "\n\n[eclaw: cumulative token limit for this prompt exceeded]"))
                  (message "eclaw: token limit exceeded for this prompt"))
                (if user-appended
                    (progn
                      (setq eclaw-conversation
                            (nconc eclaw-conversation
                                   (list (eclaw-assistant-message content))))
                      (throw 'eclaw-chat-done content))
                  (eclaw-update-conversation prompt content)
                  (throw 'eclaw-chat-done content))))))))))

(defun eclaw-update-conversation (prompt content)
  "Append PROMPT and assistant CONTENT to `eclaw-conversation'.
CONTENT may be nil; it is stored as an empty string.  Used for plain
(non-tool) replies after the model responds."
  (setq eclaw-conversation
        (nconc
         eclaw-conversation
         (list
          (eclaw-user-message prompt)
          (eclaw-assistant-message (or content ""))))))

;;; Response buffer parsing

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

;;; Logging (each HTTP exchange)

(defun eclaw-log (request-payload response)
  "Record REQUEST-PAYLOAD and RESPONSE via `eclaw-append-json-log' (one line)."
  (eclaw-append-json-log
   `((timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
     (model . ,eclaw-model)
     (request . ,request-payload)
     (response . ,response))))

;;; Choice/message accessors (parsed completion alist)

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
Nil is normal when the model issued `tool_calls' instead of text."
  (alist-get 'content (eclaw-get-message response)))

(defun eclaw-get-tool-calls (response)
  "From RESPONSE, return the assistant's `tool_calls' list or nil.
Each element follows the API tool-call shape (id, type, function, ...)."
  (alist-get 'tool_calls (eclaw-get-message response)))

(defun eclaw-get-finish-reason (response)
  "From RESPONSE, return `finish_reason' for the first choice or nil.
Useful when debugging why a completion stopped (e.g. `stop', `tool_calls')."
  (alist-get 'finish_reason (eclaw-get-first-choice response)))

(defun eclaw-report-usage (usage)
  "Display token counts from USAGE alist in the echo area."
  (message
   "Prompt: %s  Completion: %s  Total: %s"
   (alist-get 'prompt_tokens usage)
   (alist-get 'completion_tokens usage)
   (alist-get 'total_tokens usage)))

;;; Interactive entry points

(defun eclaw-agent-chat (prompt)
  "Prompt for PROMPT, call `eclaw-chat', append exchange to buffer `*eclaw*'.
PROMPT is read interactively when called as a command."
  (interactive "sPrompt: ")
  (let ((response (eclaw-chat prompt)))
    (with-current-buffer (get-buffer-create "*eclaw*")
      (goto-char (point-max))

      (insert "\n\nYou:\n")
      (insert prompt)
      
      (insert "\n\nAssistant:\n")
      (insert response)

      (display-buffer (current-buffer)))))

(defun eclaw-explain-buffer ()
  "Send the current buffer's text as code to be explained via `eclaw-agent-chat'."
  (interactive)
  (eclaw-agent-chat
   (concat
    "Explain this code:\n\n"
    (buffer-string))))

;;; JSONL log file

(defvar eclaw-agent-log-file
  (expand-file-name "~/.emacs.d/eclaw-log.jsonl")
  "File path for JSONL log lines written by `eclaw-append-json-log'.")

(defun eclaw-append-json-log (data)
  "Append DATA, JSON-encoded, as one line to `eclaw-agent-log-file'."
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

(defun eclaw-extract-usage (response)
  "Return the `usage' alist from parsed RESPONSE, or nil if absent."
  (alist-get 'usage response))

(provide 'eclaw)
;;; eclaw.el ends here
