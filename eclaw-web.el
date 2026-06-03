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
;; web requests so tools run without minibuffer prompts.
;;
;; Shares global `eclaw-conversation' with `M-x eclaw-agent-chat' and `*eclaw*'.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'web-server)
(require 'eclaw)

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

(defcustom eclaw-web-project-root nil
  "Directory used as `default-directory' during web chat.
When nil, uses `eclaw--session-project' or `default-directory' at request time."
  :type 'string
  :group 'eclaw-web)

(defvar eclaw-web-server nil
  "The active `ws-server' object, or nil when stopped.")

(defvar eclaw-web--data-dir nil
  "Directory containing `web/chat.html', set from `load-file-name'.")

(declare-function eclaw--eclaw-buffer-append "eclaw" (text))
(declare-function eclaw--eclaw-buffer-setup "eclaw" ())
(declare-function eclaw-chat "eclaw" (prompt))
(declare-function eclaw-reset-conversation "eclaw" ())

(defun eclaw-web--data-dir ()
  "Return the directory holding static web assets."
  (or eclaw-web--data-dir
      (file-name-directory (or load-file-name buffer-file-name default-directory))))

(defun eclaw-web--read-file (name)
  "Return the unibyte contents of NAME under `eclaw-web--data-dir'/web/."
  (with-temp-buffer
    (insert-file-contents-literally
     (expand-file-name (concat "web/" name) (eclaw-web--data-dir)))
    (buffer-string)))

(defun eclaw-web--project-root ()
  "Return the project directory for web chat requests."
  (expand-file-name
   (or eclaw-web-project-root
       eclaw--session-project
       default-directory)))

(defun eclaw-web--url ()
  (format "http://%s:%d/" eclaw-web-host eclaw-web-port))

(defun eclaw-web--request-path (request method)
  "Return the URL path for REQUEST and HTTP METHOD keyword."
  (cdr (assoc method (ws-headers request))))

(defun eclaw-web--json-response (process status alist)
  "Send JSON-encoded ALIST to PROCESS with HTTP STATUS."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string))
    (ws-response-header process status '("Content-type" . "application/json"))
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

(defun eclaw-web--ensure-session ()
  "Set session markers on first web chat, mirroring `eclaw-agent-chat'."
  (unless eclaw--session-started
    (setq eclaw--session-started (current-time))
    (setq eclaw--session-project (eclaw-web--project-root))))

(defun eclaw-web--append-transcript (prompt reply)
  "Append a user/assistant exchange to `*eclaw*' when possible."
  (let ((buf (get-buffer-create "*eclaw*")))
    (with-current-buffer buf
      (eclaw--eclaw-buffer-setup)
      (eclaw--eclaw-buffer-append
       (concat "\n\nYou:\n" prompt "\n\nAssistant:\n" reply "\n")))))

(defun eclaw-web--with-web-context (fun)
  "Run FUN with web project directory and tool approval disabled."
  (let ((default-directory (eclaw-web--project-root))
        (eclaw-tool-approval-mode 'off))
    (funcall fun)))

(defun eclaw-web--handle-get-index (request)
  (with-slots (process) request
    (ws-response-header process 200 '("Content-type" . "text/html; charset=utf-8"))
    (process-send-string process (eclaw-web--read-file "chat.html"))))

(defun eclaw-web--handle-post-chat (request)
  (with-slots (process body) request
    (condition-case err
        (let* ((data (eclaw-web--parse-json-body body))
               (message (alist-get 'message data)))
          (if (and message (stringp message) (not (string-empty-p message)))
              (progn
                (eclaw-web--ensure-session)
                (let ((reply
                       (eclaw-web--with-web-context
                        (lambda () (eclaw-chat message)))))
                  (eclaw-web--append-transcript message reply)
                  (eclaw-web--json-response
                   process 200 `((reply . ,reply) (error . nil)))))
              (eclaw-web--json-response
               process 400
               '((reply . nil)
                 (error . "missing or empty \"message\"")))))
      (error
       (eclaw-web--json-response
        process 500
        `((reply . nil) (error . ,(error-message-string err))))))))

(defun eclaw-web--handle-post-reset (request)
  (with-slots (process) request
    (eclaw-web--with-web-context #'eclaw-reset-conversation)
    (eclaw-web--json-response process 200 '((ok . true)))))

(defun eclaw-web--handle-request (request)
  "Route REQUEST to the appropriate handler."
  (let ((get-path (eclaw-web--request-path request :GET))
        (post-path (eclaw-web--request-path request :POST)))
    (cond
     ((and get-path (string= get-path "/"))
      (eclaw-web--handle-get-index request))
     ((and post-path (string= post-path "/api/chat"))
      (eclaw-web--handle-post-chat request))
     ((and post-path (string= post-path "/api/reset"))
      (eclaw-web--handle-post-reset request))
     (t (ws-send-404 (ws-process request))))))

;;;###autoload
(defun eclaw-web-start ()
  "Start the local eclaw web chat server on `eclaw-web-host' and `eclaw-web-port'."
  (interactive)
  (when eclaw-web-server
    (user-error "eclaw web server already running at %s" (eclaw-web--url)))
  (let ((file (or load-file-name (locate-file "eclaw-web.el" load-path))))
    (unless file (error "Cannot find eclaw-web.el on load-path"))
    (setq eclaw-web--data-dir (file-name-directory file)))
  (setq eclaw-web-server
        (ws-start #'eclaw-web--handle-request eclaw-web-port nil
                  :host eclaw-web-host))
  (message "eclaw web: %s" (eclaw-web--url)))

;;;###autoload
(defun eclaw-web-stop ()
  "Stop the eclaw web chat server if it is running."
  (interactive)
  (when eclaw-web-server
    (ws-stop eclaw-web-server)
    (setq eclaw-web-server nil)
    (message "eclaw web server stopped")))

;;;###autoload
(defun eclaw-web-open ()
  "Open the eclaw web chat page in the default browser."
  (interactive)
  (unless eclaw-web-server
    (user-error "eclaw web server is not running; use `eclaw-web-start' first"))
  (browse-url (eclaw-web--url)))

(provide 'eclaw-web)
;;; eclaw-web.el ends here
