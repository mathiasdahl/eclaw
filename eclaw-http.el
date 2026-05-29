;;; eclaw-http.el --- HTTP transport for eclaw  -*- lexical-binding: nil -*-

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
;; Low-level OpenRouter POST and response parsing: unibyte UTF-8 outgoing
;; requests, JSON completion objects, and accessors (`eclaw-get-message', …).
;; Request payloads that include `tools` are built in `eclaw.el' as
;; `eclaw-build-chat-payload` (calls `eclaw-tool-definitions' from
;; `eclaw-tools.el', loaded by `eclaw.el' before this file).
;;
;; Regression notes: `docs/http-transport.md'.
;;

;;; Code:

(require 'url)
(require 'json)

;; Runtime: `eclaw' is loaded first; these quiet `batch-byte-compile'.
(defvar eclaw-debug)
(declare-function eclaw-debug-message "eclaw" (format-string &rest args))
(declare-function eclaw-get-api-key "eclaw" ())

(eval-when-compile
  (defvar url-http-response-status)
  (defvar url-http-end-of-headers))

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
Guards regressions: outbound HTTP must use `eclaw--http-post' only."
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

(provide 'eclaw-http)
;;; eclaw-http.el ends here
