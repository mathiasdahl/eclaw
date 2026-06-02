;;; eclaw-tools.el --- Tool registry, handlers, and dispatch for eclaw  -*- lexical-binding: nil -*-

;; Copyright (C) 2026-2026  Mathias Dahl

;; Author: Mathias Dahl <mathias.dahl@gmail.com>
;; Maintainer: Mathias Dahl <mathias.dahl@gmail.com>

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
;; `eclaw-deftool' registry, local tool handlers (read/search/write),
;; sensitive-path policy, and dispatch (`eclaw--dispatch-one-tool-call').
;;

;;; Code:

(require 'json)
(require 'subr-x)
(require 'seq)
(require 'eclaw-skills)

(declare-function eclaw-debug-message "eclaw" (format-string &rest args))
(declare-function eclaw--eclaw-buffer-append "eclaw" (text))
(declare-function eclaw-tool-message "eclaw" (tool-call-id content))

(defvar eclaw-data-dir)

;;; Tools (registry and `eclaw-deftool')

(defvar eclaw--tool-registry (make-hash-table :test 'equal)
  "Maps tool name string to plist (:description :parameters :handler :risk).
Populated by `eclaw-deftool'.  :risk is `:read' (default) or `:write'.")

(defconst eclaw--tool-call-not-approved-msg
  "Error: tool execution not approved (eclaw)."
  "Sent to the model when a gated tool is skipped (user refusal or batch deny).")

(defvar eclaw-tools-enabled t
  "When non-nil, include registered tools in outgoing chat requests.
When nil, behave like text-only completions regardless of registry contents.")

(defcustom eclaw-tool-approval-mode 'all
  "How strictly to gate tool execution with `eclaw--dispatch-one-tool-call'.

Default is `all' so new installs prompt before any local tool runs (reads
and writes).  Use saved or session allow rules, or set this to `off', once
you trust the workflow.

`off' — run tools immediately (no prompts).

`writes' — interactively approve each call to tools tagged `:write'
          (`notes_write_text', `skill_write', …).

`all' — interactively approve every registered tool before it runs."
  :type '(choice (const :tag "Off (no approval)" off)
                 (const :tag "Writes only (prompt before :write)" writes)
                 (const :tag "All tools (prompt every call)" all))
  :group 'eclaw)

(defcustom eclaw-tool-approval-noninteractive 'deny
  "Behavior when tool approval is active and Emacs is batch / noninteractive.

Used when `eclaw-tool-approval-mode' is not `off' and code would prompt,
but batch Emacs (`noninteractive' non-nil): no minibuffer exists.

`deny' — do not execute gated tools (return refusal text to the model).
`allow' — run handlers without prompting (for scripted or batch jobs)."
  :type '(choice (const :tag "Deny gated tools" deny)
                 (const :tag "Allow gated tools (no prompt)" allow))
  :group 'eclaw)

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

(defcustom eclaw-read-default-line-limit 250
  "Default maximum lines returned by `read_file' when `limit' is omitted."
  :type 'integer
  :group 'eclaw)

(defconst eclaw-read-max-line-limit 1000
  "Hard cap on lines returned by `read_file'.")

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

(eval-and-compile

(defun eclaw--normalize-tool-risk (risk)
  "Return `:write' if RISK is `:write', otherwise `:read'."
  (if (eq risk :write) :write :read))

(defun eclaw--deftool-leading-options-p (form)
  "Non-nil when FORM is a property list of `eclaw-deftool' options.
Recognized keys include `:risk' (value `:read' or `:write')."
  (and (consp form)
       (keywordp (car form))
       (plist-member form :risk)))

) ;; eval-and-compile

(defun eclaw--register-tool (name description parameters-schema handler
                              &optional risk)
  "Register a tool NAME (string) for the API and for dispatch.
PARAMETERS-SCHEMA is the JSON Schema `parameters' object (type object,
properties, required).  HANDLER is `(lambda (args) ...)' with ARGS an
alist of symbol keys from parsed tool arguments.
Optional RISK is `:read' (default) or `:write' (side effects on disk)."
  (puthash name
           (list :description description
                 :parameters parameters-schema
                 :handler handler
                 :risk (eclaw--normalize-tool-risk (or risk :read)))
           eclaw--tool-registry))

(defun eclaw--tool-risk-class (tool-name)
  "Return TOOL-NAME's risk symbol `:read' or `:write', default `:read'."
  (if-let ((info (gethash tool-name eclaw--tool-registry)))
      (eclaw--normalize-tool-risk (plist-get info :risk))
    :read))

(defun eclaw--tool-call-would-require-approval-p (tool-name)
  "Non-nil when `eclaw-tool-approval-mode' gates execution of TOOL-NAME."
  (pcase eclaw-tool-approval-mode
    ('off nil)
    ('writes (eq (eclaw--tool-risk-class tool-name) :write))
    ('all t)
    (_ nil)))

(defvar eclaw--tool-approval-rules nil
  "Alist of (RULE-KEY . POLICY) persisted allow rules under `eclaw-data-dir'.
RULE-KEY is a tool name string (global) or a list `(TOOL-NAME PROJECT ARGS-KEY)'
with nil wildcards for broader scopes.  POLICY is the symbol `allow'.  Loaded
lazily from `eclaw--tool-approval-rules-file'.")

(defvar eclaw--tool-approval-rules-loaded nil
  "Non-nil once `eclaw--tool-approval-rules-load' has run.")

(defvar eclaw--tool-approval-session-rules nil
  "Alist of (RULE-KEY . POLICY) in-memory allow rules for this Emacs session.
Same key shapes as `eclaw--tool-approval-rules'; cleared when Emacs exits.")

(defun eclaw--tool-approval-normalize-rule-key (key)
  "Return RULE-KEY as `(TOOL-NAME PROJECT ARGS-KEY)' with nil wildcards."
  (pcase key
    ((guard (stringp key)) (list key nil nil))
    (`(,name) (list name nil nil))
    (`(,name ,proj) (list name proj nil))
    (`(,name ,proj ,args) (list name proj args))
    (_ (error "Invalid tool approval rule key: %S" key))))

(defun eclaw--tool-approval-rule-key-valid-p (key)
  "Non-nil when KEY is a valid persisted rule key."
  (condition-case nil
      (let ((parts (eclaw--tool-approval-normalize-rule-key key)))
        (and (stringp (nth 0 parts))
             (or (null (nth 1 parts)) (stringp (nth 1 parts)))
             (or (null (nth 2 parts)) (stringp (nth 2 parts)))))
    (error nil)))

(defun eclaw--tool-approval-rule-valid-p (rule)
  "Non-nil when RULE is a well-formed `(key . allow)' entry."
  (and (consp rule)
       (eclaw--tool-approval-rule-key-valid-p (car rule))
       (eq (cdr rule) 'allow)))

(defun eclaw--tool-approval-key-matches-p (stored-key query-key)
  "Non-nil when STORED-KEY matches QUERY-KEY (stored nil = wildcard)."
  (let ((ss (eclaw--tool-approval-normalize-rule-key stored-key))
        (sq (eclaw--tool-approval-normalize-rule-key query-key)))
    (and (string= (nth 0 ss) (nth 0 sq))
         (or (null (nth 1 ss)) (equal (nth 1 ss) (nth 1 sq)))
         (or (null (nth 2 ss)) (equal (nth 2 ss) (nth 2 sq))))))

(defun eclaw--tool-approval-rule-key-equal-p (a b)
  "Non-nil when A and B denote the same persisted rule key."
  (equal (eclaw--tool-approval-normalize-rule-key a)
         (eclaw--tool-approval-normalize-rule-key b)))

(defun eclaw--tool-approval-canonical-args-key (args)
  "Return a stable string key from parsed tool ARGS alist, or nil when empty."
  (when (and args (cdr args))
    (let* ((pairs
            (sort
             (mapcar (lambda (pair)
                       (cons (symbol-name (car pair)) (cdr pair)))
                     args)
             (lambda (a b) (string< (car a) (car b)))))
           (json-object-type 'alist)
           (json-array-type 'list)
           (json-key-type 'string))
      (json-encode pairs))))

(defun eclaw--tool-approval-query-key (tool-name args)
  "Build the query key for TOOL-NAME and parsed ARGS."
  (list tool-name
        (eclaw--skills-project-root)
        (and args (eclaw--tool-approval-canonical-args-key args))))

(defun eclaw--tool-approval-rules-file ()
  "Return the path to the persisted tool approval rules file."
  (expand-file-name "tool-approval-rules.el"
                    (expand-file-name eclaw-data-dir)))

(defun eclaw--tool-approval-rules-load ()
  "Load `eclaw--tool-approval-rules' from disk once per session."
  (unless eclaw--tool-approval-rules-loaded
    (setq eclaw--tool-approval-rules-loaded t)
    (setq eclaw--tool-approval-rules
          (let ((path (eclaw--tool-approval-rules-file)))
            (if (file-readable-p path)
                (condition-case nil
                    (with-temp-buffer
                      (insert-file-contents path)
                      (goto-char (point-min))
                      (let ((rules (read (current-buffer))))
                        (if (and (listp rules)
                                 (seq-every-p #'eclaw--tool-approval-rule-valid-p
                                              rules))
                            rules
                          (progn
                            (message "eclaw: ignoring invalid tool approval rules in %s"
                                     path)
                            nil))))
                  (error
                   (message "eclaw: could not read tool approval rules from %s"
                            path)
                   nil))
              nil)))))

(defun eclaw--tool-approval-rules-save ()
  "Write `eclaw--tool-approval-rules' to `eclaw--tool-approval-rules-file'."
  (let ((path (eclaw--tool-approval-rules-file)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (let ((print-length nil)
            (print-level nil))
        (prin1 eclaw--tool-approval-rules (current-buffer))))))

(defun eclaw--tool-approval-rules-allows-p (rules tool-name &optional args)
  "Non-nil when RULES contains an `allow' entry matching TOOL-NAME and ARGS."
  (let ((query (eclaw--tool-approval-query-key tool-name args)))
    (cl-some (lambda (rule)
               (and (eclaw--tool-approval-key-matches-p (car rule) query)
                    (eq (cdr rule) 'allow)))
             rules)))

(defun eclaw--tool-approval-rule-allows-p (tool-name &optional args)
  "Non-nil when a persisted `allow' rule matches TOOL-NAME and ARGS."
  (eclaw--tool-approval-rules-load)
  (eclaw--tool-approval-rules-allows-p eclaw--tool-approval-rules
                                       tool-name args))

(defun eclaw--tool-approval-session-rule-allows-p (tool-name &optional args)
  "Non-nil when a session `allow' rule matches TOOL-NAME and ARGS."
  (eclaw--tool-approval-rules-allows-p eclaw--tool-approval-session-rules
                                       tool-name args))

(defun eclaw--tool-approval-rule-add-to (rules-var key)
  "Add or replace an `allow' rule for KEY in the RULES-VAR alist."
  (set rules-var
       (cons (cons key 'allow)
             (cl-remove-if (lambda (rule)
                             (eclaw--tool-approval-rule-key-equal-p
                              (car rule) key))
                           (symbol-value rules-var)))))

(defun eclaw--tool-approval-rule-add (key)
  "Persist an `allow' rule for KEY and save to disk."
  (eclaw--tool-approval-rules-load)
  (eclaw--tool-approval-rule-add-to 'eclaw--tool-approval-rules key)
  (eclaw--tool-approval-rules-save))

(defun eclaw--tool-approval-session-rule-add (key)
  "Remember an `allow' rule for KEY until Emacs exits."
  (eclaw--tool-approval-rule-add-to 'eclaw--tool-approval-session-rules key))

(defun eclaw--tool-approval-rule-key-description (key)
  "Human-readable description of persisted rule KEY."
  (pcase (eclaw--tool-approval-normalize-rule-key key)
    (`(,name nil nil) (format "tool `%s' (global)" name))
    (`(,name ,proj nil) (format "tool `%s' in project %s" name proj))
    (`(,name ,proj ,args)
     (format "tool `%s' in project %s with args %s"
             name proj (eclaw--truncate-string args 120)))))

(defun eclaw--tool-approval-rule-add-allow (tool-name)
  "Persist a global `allow' rule for TOOL-NAME (backward-compatible helper)."
  (eclaw--tool-approval-rule-add tool-name))

(defun eclaw--user-approves-tool-call-p (tool-name json-args-summary args)
  "Ask whether TOOL-NAME may run with parsed ARGS.
JSON-ARGS-SUMMARY is echoed (truncated).
Return `once', `session', `session-project', `session-exact', `remember',
`remember-project', `remember-exact', or nil."
  (let* ((project (eclaw--skills-project-root))
         (args-key (and args (eclaw--tool-approval-canonical-args-key args)))
         (question
          (concat (format "eclaw: allow tool `%s'? " tool-name)
                  (unless (string-empty-p json-args-summary)
                    (format "\narguments: %s\n"
                            (eclaw--truncate-string json-args-summary 240)))
                  " "))
         (answers
          '(("allow" ?a "Run this tool call once")
            ("session" ?s "Allow this tool for this Emacs session (global)")
            ("remember" ?r "Always allow this tool (global, saved)")
            ("deny" ?d "Skip; send refusal to the model"))))
    (when project
      (setq answers
            (append
             `(("session-project" ?i
                ,(format "Allow `%s' for this Emacs session in this project" tool-name))
               ("remember-project" ?p
                ,(format "Always allow `%s' in this project (saved)" tool-name)))
             answers)))
    (when (and project args-key)
      (setq answers
            (append
             '(("session-exact" ?t
                "Allow this tool with these arguments for this Emacs session")
               ("remember-exact" ?e
                "Always allow this tool with these arguments in this project (saved)"))
             answers)))
    (condition-case nil
        (if (fboundp 'read-answer)
            (let ((read-answer-short t))
              (pcase (read-answer question answers)
              ("allow" 'once)
              ("session"
               (eclaw--tool-approval-session-rule-add tool-name)
               'session)
              ("session-project"
               (eclaw--tool-approval-session-rule-add (list tool-name project))
               'session-project)
              ("session-exact"
               (eclaw--tool-approval-session-rule-add
                (list tool-name project args-key))
               'session-exact)
              ("remember"
               (eclaw--tool-approval-rule-add tool-name)
               'remember)
              ("remember-project"
               (eclaw--tool-approval-rule-add (list tool-name project))
               'remember-project)
              ("remember-exact"
               (eclaw--tool-approval-rule-add (list tool-name project args-key))
               'remember-exact)
              (_ nil)))
          (if (y-or-n-p question) 'once nil))
      (quit nil))))

;;;###autoload
(defun eclaw-list-tool-approval-rules ()
  "List persisted tool approval rules in a temporary buffer."
  (interactive)
  (eclaw--tool-approval-rules-load)
  (let ((buf (get-buffer-create "*eclaw tool approval rules*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "eclaw tool approval rules\n")
        (insert (format "File: %s\n\n" (eclaw--tool-approval-rules-file)))
        (if eclaw--tool-approval-rules
            (dolist (rule eclaw--tool-approval-rules)
              (insert (format "- %s\n" (eclaw--tool-approval-rule-key-description
                                       (car rule)))))
          (insert "(no rules)\n"))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

;;;###autoload
(defun eclaw-remove-tool-approval-rule ()
  "Remove one persisted tool approval rule via completion."
  (interactive)
  (eclaw--tool-approval-rules-load)
  (if (null eclaw--tool-approval-rules)
      (message "eclaw: no tool approval rules to remove")
    (let* ((candidates
            (mapcar (lambda (rule)
                      (cons (eclaw--tool-approval-rule-key-description (car rule))
                            (car rule)))
                    eclaw--tool-approval-rules)
           (desc (completing-read "Remove rule: " candidates nil t))
           (key (cdr (assoc-string desc candidates))))
      (unless key
        (user-error "No matching tool approval rule"))
      (setq eclaw--tool-approval-rules
            (cl-remove-if (lambda (rule)
                            (eclaw--tool-approval-rule-key-equal-p (car rule) key))
                          eclaw--tool-approval-rules))
      (eclaw--tool-approval-rules-save)
      (message "eclaw: removed tool approval rule: %s"
               (eclaw--tool-approval-rule-key-description key))))))

;;;###autoload
(defun eclaw-clear-tool-approval-rules ()
  "Delete all persisted tool approval allow rules."
  (interactive)
  (eclaw--tool-approval-rules-load)
  (when (and eclaw--tool-approval-rules
             (y-or-n-p "Delete all eclaw tool approval rules?"))
    (progn
      (setq eclaw--tool-approval-rules nil)
      (eclaw--tool-approval-rules-save)
      (message "eclaw: cleared all tool approval rules"))))

(defun eclaw--tool-approval-transcript-line (tool-name args-summary allowed-p context)
  "Append one approval/denial audit line when buffer `*eclaw*' exists.

TOOL-NAME and JSON-ARGS-SUMMARY are as in tool dispatch (ARGS-SUMMARY may be
empty).  ALLOWED-P is whether the handler will run.

CONTEXT is `interactive' — user allowed once — `session' / `session-project' /
`session-exact' — user allowed for this Emacs session — `remember' /
`remember-project' / `remember-exact' — user allowed and saved a rule —
`session-rule' — a session allow rule matched — `saved-rule' — a persisted
allow rule matched — or `batch' — Emacs runs with `noninteractive' non-nil and
`eclaw-tool-approval-noninteractive' decides.  Silence when `*eclaw*' is absent."
  (when-let ((buf (get-buffer "*eclaw*")))
    (let ((suffix
           (pcase context
             ('interactive
              (if allowed-p "allowed interactively" "denied interactively"))
             ('session
              (if allowed-p
                  "allowed interactively for this Emacs session (global)"
                "denied interactively"))
             ('session-project
              (if allowed-p
                  "allowed interactively for this Emacs session (this project)"
                "denied interactively"))
             ('session-exact
              (if allowed-p
                  "allowed interactively for this Emacs session (project + args)"
                "denied interactively"))
             ('remember
              (if allowed-p
                  "allowed interactively and remembered (global)"
                "denied interactively"))
             ('remember-project
              (if allowed-p
                  "allowed interactively and remembered (this project)"
                "denied interactively"))
             ('remember-exact
              (if allowed-p
                  "allowed interactively and remembered (project + args)"
                "denied interactively"))
             ('session-rule
              (if allowed-p "allowed by session rule" "denied by session rule"))
             ('saved-rule
              (if allowed-p "allowed by saved rule" "denied by saved rule"))
             ('batch
              (if allowed-p
                  "allowed in batch Emacs (`noninteractive')"
                "denied in batch Emacs (`noninteractive')"))
             (_ (error "eclaw internal error: unknown transcript context %S" context)))))
      (with-current-buffer buf
        (eclaw--eclaw-buffer-append
         (concat "[eclaw: tool approval] "
                 (if allowed-p "ALLOW" "DENY")
                 " `"
                 tool-name
                 "'"
                 (let ((tail (string-trim (or args-summary ""))))
                   (if (string-empty-p tail)
                       ""
                     (concat " "
                             (eclaw--truncate-string tail 200))))
                 " — " suffix "\n"))))))

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

(defmacro eclaw-deftool (name description params &rest rest)
  "Declare a model-invokable tool.
NAME is a symbol (API name is `symbol-name' of NAME).  DESCRIPTION is a
short string for the API.  PARAMS is a list of (SYM TYPE-KEYWORD DESC [:optional]).
TYPE-KEYWORD is :string, :integer, etc.; each SYM is bound in BODY
from the parsed arguments alist passed to the implementation.
Use `:optional' as fourth element to omit the property from JSON `required'.

Optional leading property list `(:risk :write)' or `(:risk :read)' may
appear immediately before BODY (default `:read').  BODY should return a
string (tool result content for the model)."
  (declare (indent 2))
  (unless (stringp description)
    (error "`eclaw-deftool' description must be a string"))
  (let* ((props (when (eclaw--deftool-leading-options-p (car rest))
                  (pop rest)))
         (risk (if props (or (plist-get props :risk) :read) :read))
         (body rest)
         (bindings
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
          ,@body))
      ,risk)))

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

(defun eclaw--read-split-lines (file)
  "Read FILE literally and return a list of line strings (no trailing newlines)."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (let ((text (buffer-string)))
      (if (string-empty-p text)
          nil
        (mapcar (lambda (line)
                  (replace-regexp-in-string "\\`\r\\'" "" line))
                (split-string text "\n"))))))

(defun eclaw--read-effective-line-limit (limit)
  "Return positive line limit from LIMIT, default, or hard cap."
  (let ((lim (if (and limit (integerp limit) (> limit 0))
                 limit
               eclaw-read-default-line-limit)))
    (min lim eclaw-read-max-line-limit)))

(defun eclaw--read-resolve-start-line (offset total-lines)
  "Return 1-indexed start line from OFFSET and TOTAL-LINES, or nil when invalid."
  (cond
   ((null offset) 1)
   ((not (integerp offset)) nil)
   ((= offset 0) nil)
   ((< offset 0) (max 1 (+ total-lines offset 1)))
   (t offset)))

(defun eclaw--read-format-lines (lines start-line end-line truncated-p line-limit)
  "Format LINES from START-LINE through END-LINE (1-indexed) with line-number prefixes."
  (let* ((width (max 6 (length (number-to-string end-line))))
         (fmt (format "%%%dd|%%s" width))
         (out nil)
         (line-num start-line))
    (while (and lines (<= line-num end-line))
      (push (format fmt line-num (car lines)) out)
      (setq lines (cdr lines)
            line-num (1+ line-num)))
    (let ((body (string-join (nreverse out) "\n")))
      (if truncated-p
          (concat body
                  (format "\n[eclaw: line limit %d reached]" line-limit))
        body))))

(defun eclaw-tool-read-file (path &optional offset limit)
  "Read the file at PATH and return numbered lines as a string.
Optional OFFSET is a 1-indexed start line (negative counts from EOF).
Optional LIMIT caps how many lines are returned.  When `eclaw--path-sensitive-p'
holds, return `eclaw--sensitive-path-msg'.  On other errors, return a
human-readable description instead of signaling."
  (let ((file (expand-file-name path)))
    (cond
     ((eclaw--path-sensitive-p file)
      eclaw--sensitive-path-msg)
     ((and limit (not (integerp limit)))
      "Error: read_file limit must be an integer.")
     ((and limit (<= limit 0))
      "Error: read_file limit must be a positive integer.")
     ((and offset (not (integerp offset)))
      "Error: read_file offset must be an integer.")
     ((and offset (= offset 0))
      "Error: read_file offset must be >= 1 or negative (counts from end).")
     (t
      (condition-case err
          (let* ((all-lines (eclaw--read-split-lines file))
                 (total (length all-lines))
                 (start (eclaw--read-resolve-start-line offset total))
                 (line-limit (eclaw--read-effective-line-limit limit))
                 (end (min total (+ start line-limit -1)))
                 (truncated-p (or (and limit (> limit eclaw-read-max-line-limit))
                                  (and (null limit) (< end total)))))
            (cond
             ((null start)
              "Error: read_file offset must be >= 1 or negative (counts from end).")
             ((and (> start 0) (> start total))
              (format "Error: read_file offset %d beyond end of file (%d lines)"
                      start total))
             ((zerop total)
              "")
             (t
              (eclaw--read-format-lines
               (seq-subseq all-lines (1- start) end)
               start end truncated-p line-limit))))
        (error (format "Error reading file %S: %S" file err)))))))



(eclaw-deftool read_file
  "Read text from a file on disk. Optional offset/limit return a line range."
  ((path :string "File path (absolute or relative to default directory).")
   (offset :integer
           "1-indexed start line. Negative counts from end (e.g. -1 = last line)."
           :optional)
   (limit :integer
          "Maximum number of lines to return."
          :optional))
  (if path
      (progn
        (when (and (not (eclaw--path-sensitive-p path))
                   (eclaw--path-is-project-skill-md-p path))
          (eclaw-debug-message "eclaw: skill file read (model loaded skill): %s"
                   (expand-file-name path)))
        (eclaw-tool-read-file path offset limit))
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
  (:risk :write)
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
  (:risk :write)
  (if skill_dir
      (if content
          (eclaw-tool-skill-write skill_dir content)
        "Error: skill_write requires \"content\" in arguments.")
    "Error: skill_write requires \"skill_dir\" in arguments."))

(defun eclaw--dispatch-one-tool-call (tool-call)
  "Execute the TOOL-CALL alist from the API; return the tool result string.
TOOL-CALL follows the API tool-call shape (`function.name', `function.arguments'
JSON).  Dispatches via `eclaw--tool-registry'; unknown tools yield a short
error string.

When `eclaw-tool-approval-mode' requires approval, check persisted allow rules
(`eclaw--tool-approval-rule-allows-p'), then session allow rules
(`eclaw--tool-approval-session-rule-allows-p'), else ask in the minibuffer before
`funcall' on the handler; if the user refuses, or Emacs is batch
(non-nil variable `noninteractive'; see `eclaw-tool-approval-noninteractive'),
return
`eclaw--tool-call-not-approved-msg' without running the handler.

When buffer `*eclaw*' exists, gated outcomes are appended for the transcript
via `eclaw--tool-approval-transcript-line' (audit of allow vs deny)."
  (let* ((fn-spec (alist-get 'function tool-call))
         (name (alist-get 'name fn-spec))
         (args-str (alist-get 'arguments fn-spec))
         (args
          (let ((json-object-type 'alist)
                (json-array-type 'list)
                (json-key-type 'symbol))
            (json-read-from-string args-str)))
         (args-summary
          (let ((s (string-trim (or args-str ""))))
            (if (string-equal s "{}") "" s))))
    (message
     "eclaw: tool %s%s"
     name
     (if (string-empty-p args-summary)
         ""
       (let ((max 100))
         (if (> (length args-summary) max)
             (format " %s…" (substring args-summary 0 max))
           (format " %s" args-summary)))))
    (if-let ((info (gethash name eclaw--tool-registry))
             (handler (plist-get info :handler)))
        (let ((gated-p (eclaw--tool-call-would-require-approval-p name)))
          (cond
           ((not gated-p)
            (funcall handler args))
           ((eclaw--tool-approval-rule-allows-p name args)
            (eclaw--tool-approval-transcript-line name args-summary t 'saved-rule)
            (funcall handler args))
           ((eclaw--tool-approval-session-rule-allows-p name args)
            (eclaw--tool-approval-transcript-line name args-summary t 'session-rule)
            (funcall handler args))
           (noninteractive
            (let ((allow-p (eq eclaw-tool-approval-noninteractive 'allow)))
              (eclaw--tool-approval-transcript-line name args-summary allow-p 'batch)
              (if allow-p
                  (funcall handler args)
                eclaw--tool-call-not-approved-msg)))
           (t
            (let ((choice (eclaw--user-approves-tool-call-p name args-summary args)))
              (if (memq choice '(once session session-project session-exact
                                 remember remember-project remember-exact))
                  (progn
                    (eclaw--tool-approval-transcript-line
                     name args-summary t
                     (if (eq choice 'once) 'interactive choice))
                    (funcall handler args))
                (eclaw--tool-approval-transcript-line name args-summary nil 'interactive)
                eclaw--tool-call-not-approved-msg)))))
      (format "Unknown tool: %s" name))))

(defun eclaw--tool-result-messages (tool-calls &optional synth-reason)
  "Return a list of tool message alists, one per element of TOOL-CALLS.
Each API `tool_call_id' gets exactly one `role: tool' message.

When SYNTH-REASON is non-nil (token cap in `eclaw-chat'), handlers and the
approval gate are skipped; every call receives the same synthetic abort text so
the conversation trace stays API-valid.  See `docs/tool-approval.md'."
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

(provide 'eclaw-tools)

;;; eclaw-tools.el ends here
