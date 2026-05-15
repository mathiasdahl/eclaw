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
;;  ...
;;
;;
;;; TODO
;;
;; - Tool support
;; - read_file tool
;;

(require 'url)
(require 'json)

(defvar eclaw-api-key
  (getenv "OPENROUTER_API_KEY"))

(defun eclaw-get-api-key ()
  (unless eclaw-api-key
    (error "API key not set")))

(defvar eclaw-model
  "deepseek/deepseek-v4-flash")

(defvar eclaw-system-prompt
  (concat
   "You are eclaw, an Emacs-native AI coding assistant. "
   "You help users write, understand, debug, and refactor code inside Emacs. "
   "Be concise, technically accurate, and practical. "
   "Prefer clear explanations and incremental changes."))

(defvar eclaw-conversation nil
  "Conversation history for eclaw.")

(defun eclaw-reset-conversation ()
  (interactive)
  (setq eclaw-conversation nil)
  (message "eclaw conversation reset"))

(defun eclaw-system-message ()
  `((role . "system")
    (content . ,eclaw-system-prompt)))

(defun eclaw-user-message (content)
  `((role . "user")
    (content . ,content)))

(defun eclaw-assistant-message (content)
  `((role . "assistant")
    (content . ,content)))

(defun eclaw-build-messages (prompt)
  (append
   (list (eclaw-system-message))
   eclaw-conversation
   (list (eclaw-user-message prompt))))

(defun eclaw-chat (prompt)
  "Send PROMPT to OpenRouter and return response text."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " (eclaw-get-api-key)))
            ("Content-Type" . "application/json")))
	 (request-payload
	  `((model . ,eclaw-model)
	    (messages . ,(vconcat (eclaw-build-messages prompt)))))
         (url-request-data
          (json-encode request-payload))
         (buffer
          (url-retrieve-synchronously
           "https://openrouter.ai/api/v1/chat/completions"))
         (response (eclaw-get-response buffer))
	 (content (eclaw-get-content response)))
    (eclaw-update-conversation prompt content)
    (eclaw-log request-payload response)
    (eclaw-report-usage (alist-get 'usage response))
    content))

(defun eclaw-update-conversation (prompt content)
  (setq eclaw-conversation
        (nconc
         eclaw-conversation
         (list
          (eclaw-user-message prompt)
          (eclaw-assistant-message content)))))

(defun eclaw-get-response (buffer)
  (with-current-buffer buffer
    (goto-char url-http-end-of-headers)
    (set-buffer-multibyte t)
    (decode-coding-region (point) (point-max) 'utf-8)
    (let* ((json-object-type 'alist)
           (json-array-type 'list)
           (json-key-type 'symbol)
	   (response (json-read)))
      (kill-buffer buffer)
      response)))

(defun eclaw-log (request-payload response)
  (eclaw-append-json-log
   `((timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
     (model . ,eclaw-model)
     (request . ,request-payload)
     (response . ,response))))

(defun eclaw-get-content (response)
  (alist-get
   'content
   (alist-get
    'message
    (elt
     (alist-get 'choices response)
     0))))

(defun eclaw-report-usage (usage)
  (message
   "Prompt: %s  Completion: %s  Total: %s"
   (alist-get 'prompt_tokens usage)
   (alist-get 'completion_tokens usage)
   (alist-get 'total_tokens usage)))

(defun eclaw-agent-chat (prompt)
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
  (interactive)
  (eclaw-agent-chat
   (concat
    "Explain this code:\n\n"
    (buffer-string))))

(defvar eclaw-agent-log-file
  (expand-file-name "~/.emacs.d/eclaw-log.jsonl"))

(defun eclaw-append-json-log (data)
  "Append DATA as a JSONL entry to log file."  
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
  (alist-get 'usage response))

(provide 'eclaw)
