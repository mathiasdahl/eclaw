;;; eclaw-web.el --- Local web UI for eclaw via emacs-web-server  -*- lexical-binding: t -*-

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
;; Optional localhost HTTP chat front-end for eclaw using emacs-web-server.
;; Requires both eclaw and emacs-web-server on `load-path':
;;
;;   (add-to-list 'load-path "/path/to/emacs-web-server")
;;   (add-to-list 'load-path "/path/to/eclaw")
;;   (require 'eclaw)
;;   (require 'eclaw-web)
;;
;;   M-x eclaw-web-start
;;   M-x eclaw-web-open
;;
;; SECURITY: binds to 127.0.0.1 only. Do not expose this port on a network.
;; Tool approval is forced off (`eclaw-tool-approval-mode' `off') while handling
;; web requests so tools run without minibuffer prompts.  Disabled tools are
;; excluded by `tool-policy.el'; dangerous tools require explicit web opt-in.
;;
;; Shares global `eclaw-conversation' with `M-x eclaw-agent-chat' and `*eclaw*'.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'web-server)
(require 'eclaw)
(require 'eclaw-notify)

(defgroup eclaw-web nil
  "Local web UI for eclaw (emacs-web-server)."
  :group 'eclaw
  :prefix "eclaw-web-")

(defcustom eclaw-web-port 9876
  "TCP port for the local eclaw web chat server."
  :type 'integer
  :group 'eclaw-web)

(defcustom eclaw-web-host "127.0.0.1"
  "Host address to bind. Use 127.0.0.1 only unless you add authentication."
  :type 'string
  :group 'eclaw-web)


(defcustom eclaw-web-root nil
  "Directory containing `eclaw-web.el' and the `web/' subdirectory.
When nil, derived from where `eclaw-web.el' was loaded from (or `load-path').
Set this when static assets are not found (for example after `(require 'eclaw-web)'
from a scratch buffer with a surprising `default-directory')."
  :type 'string
  :group 'eclaw-web)

(defcustom eclaw-web-base-path ""
  "URL path prefix when eclaw is served behind a reverse proxy (e.g. \"/muuclaw\").
Incoming request paths with this prefix are stripped before routing.  The chat
page gets a matching `<base href=\"…\">' tag so relative `api/…' URLs resolve
correctly.  Leave empty when the app is mounted at the site root."
  :type 'string
  :group 'eclaw-web)

(defvar eclaw-web-server nil
  "The active `ws-server' object, or nil when stopped.")

(defvar eclaw-web--data-dir nil
  "Cached eclaw install directory; set from `load-file-name' when this file loads.")

(declare-function eclaw-message "eclaw" (format-string &rest args))
(declare-function eclaw--eclaw-buffer-append "eclaw" (text))
(declare-function eclaw--eclaw-buffer-setup "eclaw" ())
(declare-function eclaw-chat "eclaw" (prompt))
(declare-function eclaw-reset-conversation "eclaw" ())
(declare-function eclaw--folder "eclaw" ())
(declare-function eclaw-usage-stats "eclaw" ())
(declare-function eclaw-conversation-display-messages "eclaw" ())
(declare-function eclaw-conversation-last-turn-display-messages "eclaw" ())
(declare-function eclaw-list-archived-conversations "eclaw" ())
(declare-function eclaw-restore-conversation "eclaw" (file))
(declare-function eclaw-tool-policy-list "eclaw-tools" ())
(declare-function eclaw-tool-policy-apply-updates "eclaw-tools" (updates))
(declare-function eclaw-notify-add-subscription "eclaw-notify" (sub))
(declare-function eclaw-notify-remove-subscription "eclaw-notify" (endpoint))
(declare-function eclaw-notify-subscribe-secret-valid-p "eclaw-notify" (secret))
(declare-function eclaw-notify-vapid-public-key "eclaw-notify" ())

(defun eclaw-web--data-dir ()
  "Return the directory holding static web assets (`web/' under the eclaw repo)."
  (or (and eclaw-web-root
           (progn
             (let ((root (expand-file-name eclaw-web-root)))
               (unless (file-directory-p root)
                 (error "eclaw-web-root is not a directory: %s" root))
               root)))
      eclaw-web--data-dir
      (when-let ((file (locate-file "eclaw-web.el" load-path)))
        (setq eclaw-web--data-dir (file-name-directory file)))
      (error "Cannot find eclaw web assets; add eclaw to `load-path' or set `eclaw-web-root'")))

(defun eclaw-web--asset-path (name)
  "Return absolute path for web asset NAME (for example \"chat.html\")."
  (expand-file-name (concat "web/" name) (eclaw-web--data-dir)))

(defun eclaw-web--check-assets ()
  "Signal an error unless required files exist under `eclaw-web--data-dir'/web/."
  (dolist (name '("chat.html" "sw.js"))
    (let ((path (eclaw-web--asset-path name)))
      (unless (file-readable-p path)
        (error "eclaw-web: missing %s; set `eclaw-web-root' to the eclaw repo directory"
               path)))))

(defun eclaw-web--read-file (name)
  "Return the unibyte contents of NAME under `eclaw-web--data-dir'/web/."
  (with-temp-buffer
    (insert-file-contents-literally (eclaw-web--asset-path name))
    (buffer-string)))

(defun eclaw-web--default-directory ()
  "Return `default-directory' for web chat tool calls."
  (eclaw--folder))

(defun eclaw-web--base-path-normalized ()
  "Return `eclaw-web-base-path' as \"/prefix\" or \"\" when unset."
  (let ((path (or eclaw-web-base-path "")))
    (if (string-empty-p path)
        ""
      (concat "/" (string-trim-left (string-trim-right path "/") "/")))))

(defun eclaw-web--strip-base-path (path)
  "Remove `eclaw-web-base-path' from PATH when present."
  (when path
    (let ((base (eclaw-web--base-path-normalized)))
      (let ((stripped
             (if (and (not (string-empty-p base))
                      (or (string= path base)
                          (string-prefix-p (concat base "/") path)))
                 (substring path (length base))
               path)))
        (cond
         ((or (null stripped) (string-empty-p stripped)) "/")
         ((not (string-prefix-p "/" stripped)) (concat "/" stripped))
         (t stripped))))))

(defun eclaw-web--serve-chat-html ()
  "Return chat.html with deploy-specific constants for reverse-proxy setups."
  (let ((html (eclaw-web--read-file "chat.html")))
    (setq html
          (replace-regexp-in-string
           "const ECLAW_WEB_BASE = \"\";"
           (format "const ECLAW_WEB_BASE = %s;"
                   (json-encode (eclaw-web--base-path-normalized)))
           html))
    (replace-regexp-in-string
     "const ECLAW_PUSH_SUBSCRIBE_SECRET = \"\";"
     (format "const ECLAW_PUSH_SUBSCRIBE_SECRET = %s;"
             (json-encode (or eclaw-notify-subscribe-secret "")))
     html)))

(defun eclaw-web--url ()
  (format "http://%s:%d%s/" eclaw-web-host eclaw-web-port
          (eclaw-web--base-path-normalized)))

(defun eclaw-web--request-path (request method)
  "Return the URL path for REQUEST and HTTP METHOD keyword."
  (eclaw-web--strip-base-path (cdr (assoc method (ws-headers request)))))

(defun eclaw-web--json-response (process status alist)
  "Send JSON-encoded ALIST to PROCESS with HTTP STATUS."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string))
    (ws-response-header process status
                        '("Content-type" . "application/json")
                        '("Cache-Control" . "no-store"))
    (process-send-string process (json-encode alist))))

(defun eclaw-web--parse-json-body (body)
  "Parse JSON string BODY; return alist or signal on failure."
  (unless (and body (not (string-empty-p body)))
    (error "empty request body"))
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (condition-case json-err
        (json-read-from-string body)
      (json-error
       (signal 'error (list "invalid JSON" (error-message-string json-err)))))))

(defun eclaw-web--parse-json-body-string-keys (body)
  "Parse JSON BODY into an alist with string keys."
  (unless (and body (not (string-empty-p body)))
    (error "empty request body"))
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string))
    (condition-case json-err
        (json-read-from-string body)
      (json-error
       (signal 'error (list "invalid JSON" (error-message-string json-err)))))))

(defun eclaw-web--append-transcript (prompt reply)
  "Append a user/assistant exchange to `*eclaw*' when possible."
  (let ((buf (get-buffer-create "*eclaw*")))
    (with-current-buffer buf
      (eclaw--eclaw-buffer-setup)
      (eclaw--eclaw-buffer-append
       (concat "\n\nYou:\n" prompt "\n\nAssistant:\n" reply "\n")))))

(defun eclaw-web--with-web-context (fun)
  "Run FUN with web project directory and tool approval disabled."
  (let ((default-directory (eclaw-web--default-directory))
        (eclaw-tool-approval-mode 'off))
    (funcall fun)))

(defun eclaw-web--handle-get-index (request)
  (with-slots (process) request
    (ws-response-header process 200 '("Content-type" . "text/html; charset=utf-8"))
    (process-send-string process (eclaw-web--serve-chat-html))))

(defun eclaw-web--handle-post-chat (request)
  (with-slots (process body) request
    (condition-case err
        (let* ((data (eclaw-web--parse-json-body body))
               (message (alist-get 'message data)))
          (if (and message (stringp message) (not (string-empty-p message)))
              (progn
                (let ((reply
                       (eclaw-web--with-web-context
                        (lambda () (eclaw-chat message)))))
                  (eclaw-web--append-transcript message reply)
                  (eclaw-web--json-response
                   process 200 `((reply . ,reply)
                                 (turn_messages . ,(eclaw-conversation-last-turn-display-messages))
                                 (error . nil)
                                 (usage . ,(eclaw-usage-stats))))))
              (eclaw-web--json-response
               process 400
               '((reply . nil)
                 (error . "missing or empty \"message\"")))))
      (error
       (eclaw-web--json-response
        process 500
        `((reply . nil) (error . ,(error-message-string err))))))))

(defun eclaw-web--handle-get-stats (request)
  (with-slots (process) request
    (eclaw-web--json-response process 200 (eclaw-usage-stats))))

(defun eclaw-web--handle-get-conversation (request)
  (with-slots (process) request
    (eclaw-web--json-response
     process 200
     `((messages . ,(eclaw-conversation-display-messages))
       (usage . ,(eclaw-usage-stats))
       (restored_from . ,(or eclaw--restored-from-file :json-false))
       (session_dirty . ,(if eclaw--session-dirty-p t :json-false))))))

(defun eclaw-web--archived-conversations-json ()
  "Return archived conversation rows as JSON-friendly alists with string keys."
  (mapcar
   (lambda (row)
     `(("file" . ,(plist-get row 'file))
       ("started" . ,(plist-get row 'started))
       ("ended" . ,(plist-get row 'ended))
       ("turns" . ,(plist-get row 'turns))
       ("preview" . ,(plist-get row 'preview))
       ("restorable" . ,(plist-get row 'restorable))))
   (eclaw-list-archived-conversations)))

(defun eclaw-web--handle-get-conversations (request)
  (with-slots (process) request
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'string))
      (ws-response-header process 200
                          '("Content-type" . "application/json")
                          '("Cache-Control" . "no-store"))
      (process-send-string process
                           (json-encode (eclaw-web--archived-conversations-json))))))

(defun eclaw-web--handle-post-conversations-restore (request)
  (with-slots (process body) request
    (condition-case err
        (let* ((data (eclaw-web--parse-json-body-string-keys body))
               (file (cdr (assoc-string "file" data))))
          (if (and file (stringp file) (not (string-empty-p file)))
              (progn
                (eclaw-web--with-web-context
                 (lambda () (eclaw-restore-conversation file)))
                (eclaw-web--json-response
                 process 200
                 `((messages . ,(eclaw-conversation-display-messages))
                   (usage . ,(eclaw-usage-stats))
                   (restored_from . ,file)
                   (session_dirty . :json-false))))
            (eclaw-web--json-response
             process 400
             '(("error" . "missing or empty \"file\"")))))
      (error
       (eclaw-web--json-response
        process 400
        `(("error" . ,(error-message-string err))))))))

(defun eclaw-web--tool-policy-json ()
  "Return tool policy rows as JSON-friendly alists with string keys."
  (mapcar
   (lambda (row)
     `(("name" . ,(plist-get row 'name))
       ("description" . ,(plist-get row 'description))
       ("risk" . ,(plist-get row 'risk))
       ("enabled" . ,(if (plist-get row 'enabled) t :json-false))))
   (eclaw-tool-policy-list)))

(defun eclaw-web--settings-response-alist ()
  "Return settings payload alist for JSON encoding."
  `(("tools" . ,(vconcat (eclaw-web--tool-policy-json)))
    ("policy_file" . ,(eclaw--tool-policy-file))
    ("models" . ,(vconcat eclaw-available-models))
    ("model" . ,(eclaw-normalize-model eclaw-model))
    ("max_tokens_per_prompt" . ,eclaw-max-tokens-per-prompt)
    ("max_completions_per_prompt" . ,eclaw-max-completions-per-prompt)
    ("push_enabled" . ,(if (and eclaw-notify-enabled (eclaw-notify-vapid-public-key))
                          t
                        :json-false))
    ("push_vapid_public_key" . ,(or (eclaw-notify-vapid-public-key) :json-null))
    ("push_on_chat_complete" . ,(if eclaw-notify-on-chat-complete t :json-false))))
(defun eclaw-web--json-bool (value)
  "Normalize JSON boolean VALUE to Emacs t/nil."
  (cond ((eq value :json-false) nil)
        ((eq value :json-true) t)
        (t value)))


(defun eclaw-web--parse-tool-policy-updates (tools-alist)
  "Return alist of tool-name string to boolean from JSON `tools' object."
  (unless (listp tools-alist)
    (error "settings body requires object \"tools\""))
  (let (updates)
    (dolist (pair tools-alist)
      (unless (stringp (car pair))
        (error "invalid tool name in settings update"))
      (let ((enabled (eclaw-web--json-bool (cdr pair))))
        (unless (member enabled '(t nil))
          (error "tool %S enabled value must be boolean" (car pair)))
        (push (cons (car pair) enabled) updates)))
    (nreverse updates)))


(defun eclaw-web--parse-model-update (model-value)
  "Return model id string from JSON `model' value."
  (unless (stringp model-value)
    (error "settings body requires string \"model\""))
  (unless (not (string-empty-p model-value))
    (error "settings body requires non-empty \"model\""))
  model-value)


(defun eclaw-web--parse-positive-integer (value field-name)
  "Return positive integer VALUE for settings field FIELD-NAME."
  (let ((n (cond
            ((integerp value) value)
            ((and (numberp value) (= value (truncate value)))
             (truncate value))
            ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
             (string-to-number value))
            (t (error "%s must be a positive integer" field-name)))))
    (unless (> n 0)
      (error "%s must be a positive integer" field-name))
    n))


(defun eclaw-web--parse-boolean-setting (value field-name)
  "Return boolean from JSON VALUE for settings field FIELD-NAME."
  (let ((enabled (eclaw-web--json-bool value)))
    (unless (member enabled '(t nil))
      (error "%s must be a boolean" field-name))
    enabled))


(defun eclaw-web--handle-get-settings (request)
  (with-slots (process) request
    (eclaw-web--json-response process 200 (eclaw-web--settings-response-alist))))

(defun eclaw-web--handle-patch-settings (request)
  (with-slots (process body) request
    (condition-case err
        (let* ((data (eclaw-web--parse-json-body-string-keys body))
               (tools-entry (assoc-string "tools" data))
               (model-entry (assoc-string "model" data))
               (max-tokens-entry (assoc-string "max_tokens_per_prompt" data))
               (max-completions-entry (assoc-string "max_completions_per_prompt" data))
               (push-on-chat-complete-entry
                (assoc-string "push_on_chat_complete" data)))
          (if (or tools-entry model-entry max-tokens-entry max-completions-entry
                  push-on-chat-complete-entry)
              (progn
                (eclaw-web--with-web-context
                 (lambda ()
                   (when model-entry
                     (eclaw-set-model
                      (eclaw-web--parse-model-update (cdr model-entry))))
                   (when max-tokens-entry
                     (setq eclaw-max-tokens-per-prompt
                           (eclaw-web--parse-positive-integer
                            (cdr max-tokens-entry) "max_tokens_per_prompt")))
                   (when max-completions-entry
                     (setq eclaw-max-completions-per-prompt
                           (eclaw-web--parse-positive-integer
                            (cdr max-completions-entry)
                            "max_completions_per_prompt")))
                   (when push-on-chat-complete-entry
                     (setq eclaw-notify-on-chat-complete
                           (eclaw-web--parse-boolean-setting
                            (cdr push-on-chat-complete-entry)
                            "push_on_chat_complete")))
                   (when tools-entry
                     (let ((tools-obj (or (cdr tools-entry) '())))
                       (eclaw-tool-policy-apply-updates
                        (eclaw-web--parse-tool-policy-updates tools-obj))))))
                (eclaw-web--json-response
                 process 200 (eclaw-web--settings-response-alist)))
            (eclaw-web--json-response
             process 400
             '(("error" . "missing settings field in request body")))))
      (error
       (eclaw-web--json-response
        process 400
        `(("error" . ,(error-message-string err))))))))


(defun eclaw-web--handle-post-settings (request)
  "Alias POST /api/settings to the PATCH handler for clients without PATCH."
  (eclaw-web--handle-patch-settings request))

(defun eclaw-web--handle-post-reset (request)
  (with-slots (process) request
    (eclaw-web--with-web-context #'eclaw-reset-conversation)
    (eclaw-web--json-response process 200 `((ok . true)
                                            (usage . ,(eclaw-usage-stats))))))

(defun eclaw-web--push-subscription-from-body (data)
  "Return subscription alist from parsed JSON DATA, omitting `secret'."
  (let (subscription)
    (dolist (pair data)
      (unless (string= (car pair) "secret")
        (push pair subscription)))
    (nreverse subscription)))

(defun eclaw-web--handle-get-sw-js (request)
  (with-slots (process) request
    (ws-response-header process 200
                        '("Content-type" . "application/javascript; charset=utf-8")
                        '("Cache-Control" . "no-store"))
    (process-send-string process (eclaw-web--read-file "sw.js"))))

(defun eclaw-web--handle-post-push-subscribe (request)
  (with-slots (process body) request
    (condition-case err
        (let* ((data (eclaw-web--parse-json-body-string-keys body))
               (secret (cdr (assoc-string "secret" data)))
               (subscription (eclaw-web--push-subscription-from-body data)))
          (cond
           ((not (eclaw-notify-subscribe-secret-valid-p secret))
            (eclaw-web--json-response process 403 '(("error" . "invalid subscribe secret"))))
           ((not (eclaw-notify-vapid-public-key))
            (eclaw-web--json-response
             process 503 '(("error" . "push not configured on server"))))
           (t
            (eclaw-notify-add-subscription subscription)
            (eclaw-web--json-response process 200 '(("ok" . true))))))
      (error
       (eclaw-web--json-response
        process 400
        `(("error" . ,(error-message-string err))))))))

(defun eclaw-web--handle-delete-push-subscribe (request)
  (with-slots (process body) request
    (condition-case err
        (let* ((data (eclaw-web--parse-json-body-string-keys body))
               (secret (cdr (assoc-string "secret" data)))
               (endpoint (cdr (assoc-string "endpoint" data))))
          (cond
           ((not (eclaw-notify-subscribe-secret-valid-p secret))
            (eclaw-web--json-response process 403 '(("error" . "invalid subscribe secret"))))
           ((not (and endpoint (stringp endpoint) (not (string-empty-p endpoint))))
            (eclaw-web--json-response process 400 '(("error" . "missing endpoint"))))
           ((eclaw-notify-remove-subscription endpoint)
            (eclaw-web--json-response process 200 '(("ok" . true))))
           (t
            (eclaw-web--json-response process 404 '(("error" . "subscription not found"))))))
      (error
       (eclaw-web--json-response
        process 400
        `(("error" . ,(error-message-string err))))))))

(defun eclaw-web--handle-request (request)
  "Route REQUEST to the appropriate handler."
  (let ((get-path (eclaw-web--request-path request :GET))
        (post-path (eclaw-web--request-path request :POST))
        (patch-path (eclaw-web--request-path request :PATCH))
        (delete-path (eclaw-web--request-path request :DELETE)))
    (cond
     ((and get-path (string= get-path "/"))
      (eclaw-web--handle-get-index request))
     ((and get-path (string= get-path "/sw.js"))
      (eclaw-web--handle-get-sw-js request))
     ((and get-path (string= get-path "/api/stats"))
      (eclaw-web--handle-get-stats request))
     ((and get-path (string= get-path "/api/conversation"))
      (eclaw-web--handle-get-conversation request))
     ((and get-path (string= get-path "/api/conversations"))
      (eclaw-web--handle-get-conversations request))
     ((and post-path (string= post-path "/api/conversations/restore"))
      (eclaw-web--handle-post-conversations-restore request))
     ((and get-path (string= get-path "/api/settings"))
      (eclaw-web--handle-get-settings request))
     ((and post-path (string= post-path "/api/chat"))
      (eclaw-web--handle-post-chat request))
     ((and post-path (string= post-path "/api/reset"))
      (eclaw-web--handle-post-reset request))
     ((and post-path (string= post-path "/api/settings"))
      (eclaw-web--handle-post-settings request))
     ((and post-path (string= post-path "/api/push/subscribe"))
      (eclaw-web--handle-post-push-subscribe request))
     ((and patch-path (string= patch-path "/api/settings"))
      (eclaw-web--handle-patch-settings request))
     ((and delete-path (string= delete-path "/api/push/subscribe"))
      (eclaw-web--handle-delete-push-subscribe request))
     (t (ws-send-404 (ws-process request))))))

;;;###autoload
(defun eclaw-web-start ()
  "Start the local eclaw web chat server on `eclaw-web-host' and `eclaw-web-port'."
  (interactive)
  (when eclaw-web-server
    (user-error "eclaw web server already running at %s" (eclaw-web--url)))
  (eclaw-web--check-assets)
  (setq eclaw-web-server
        (ws-start #'eclaw-web--handle-request eclaw-web-port nil
                  :host eclaw-web-host))
  (eclaw-message "eclaw web: %s (assets from %s)" (eclaw-web--url) (eclaw-web--data-dir)))

;;;###autoload
(defun eclaw-web-stop ()
  "Stop the eclaw web chat server if it is running."
  (interactive)
  (when eclaw-web-server
    (ws-stop eclaw-web-server)
    (setq eclaw-web-server nil)
    (eclaw-message "eclaw web server stopped")))

;;;###autoload
(defun eclaw-web-open ()
  "Open the eclaw web chat page in the default browser."
  (interactive)
  (unless eclaw-web-server
    (user-error "eclaw web server is not running; use `eclaw-web-start' first"))
  (browse-url (eclaw-web--url)))

(when load-file-name
  (setq eclaw-web--data-dir (file-name-directory load-file-name)))

(provide 'eclaw-web)
;;; eclaw-web.el ends here
