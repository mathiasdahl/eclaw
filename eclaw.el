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
;; messages and optionally advertises a `read_file' tool to the model.
;;
;; Layers (all in this file; transport is not yet split out):
;;
;; - Configuration: API key, model id, system prompt, tool definitions.
;; - Message builders: alists shaped like OpenAI chat messages; serialized
;;   with `json-encode' (symbol keys, vectors for `messages' array).
;; - HTTP: `url-retrieve-synchronously' plus strict parsing in
;;   `eclaw-get-response' (status check, JSON `error' field).
;; - Orchestration: `eclaw-chat' performs one completion; if the assistant
;;   returns non-empty `tool_calls', it runs only the first call, appends
;;   user + assistant + tool rows to history, and issues exactly one
;;   follow-up completion with no extra user text.
;; - UI: `eclaw-agent-chat' appends to buffer `*eclaw*'; logging writes
;;   JSON lines to `eclaw-agent-log-file'.
;;
;; Conversation state (`eclaw-conversation') stores only user, assistant,
;; and tool messages from prior turns—not a second copy of the system
;; message.  Each request prepends a fresh system message via
;; `eclaw-system-message'.
;;
;; Limitations: blocking HTTP, global session, at most one tool call per
;; user prompt (first call only), no streaming.

;;; Code:

(require 'url)
(require 'json)

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
   "Prefer clear explanations and incremental changes.")
  "Text of the system role message prepended to every completion request.")

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
  "Return one system message alist using `eclaw-system-prompt'."
  `((role . "system")
    (content . ,eclaw-system-prompt)))

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

;;; Tool definitions (API schema)

(defvar eclaw-tool-definitions
  (list
   '((type . "function")
     (function
      .
      ((name . "read_file")
       (description . "Read the full text of a file from disk.")
       (parameters
        .
        ((type . "object")
         (properties
          .
          ((path
            .
            ((type . "string")
             (description . "File path (absolute or relative to default directory).")))))
         (required . ["path"])))))))
  "OpenAI-format `tools' array for the API, or nil to omit tools entirely.
When non-nil, `eclaw--chat-request-payload' includes it and models may
emit `tool_calls'.  Set to nil to force text-only completions.")

;;; HTTP request construction and transport

(defun eclaw--chat-request-payload (messages)
  "Return the JSON-serializable request alist for message list MESSAGES.
MESSAGES must be a list of message alists; it is stored under key `messages'
as a vector.  Adds `tools' when `eclaw-tool-definitions' is non-nil."
  (let ((base `((model . ,eclaw-model)
               (messages . ,(vconcat messages)))))
    (if eclaw-tool-definitions
        (append base `((tools . ,eclaw-tool-definitions)))
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
PATH is expanded with `expand-file-name'.  On I/O error, returns a
human-readable description instead of signaling."
  (let ((file (expand-file-name path)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents-literally file)
          (buffer-string))
      (error (format "Error reading file %S: %S" file err)))))

(defun eclaw--first-tool-call-id (tool-calls)
  "Return the `id' string of the first element of TOOL-CALLS list."
  (alist-get 'id (car tool-calls)))

(defun eclaw--dispatch-one-tool-call (tool-call)
  "Execute the TOOL-CALL alist from the API; return the tool result string.
TOOL-CALL is the first element of the model's `tool_calls' array
(`function.name', `function.arguments' JSON).  Only `read_file' is
implemented; other names yield a short error string."
  (let* ((fn-spec (alist-get 'function tool-call))
         (name (alist-get 'name fn-spec))
         (args-str (alist-get 'arguments fn-spec))
         (args
          (let ((json-object-type 'alist)
                (json-array-type 'list)
                (json-key-type 'symbol))
            (json-read-from-string args-str))))
    (cond
     ((string= name "read_file")
      (let ((path (alist-get 'path args)))
        (if path
            (eclaw-tool-read-file path)
          "Error: read_file requires \"path\" in arguments.")))
     (t (format "Unknown tool: %s" name)))))

;;; Orchestration

(defun eclaw-chat (prompt)
  "Send user text PROMPT to the model; return the final assistant string.
When the first response includes `tool_calls', runs at most the first
call, pushes user/assistant/tool messages into `eclaw-conversation',
requests a follow-up completion, and returns that assistant text.
Otherwise appends user + assistant messages via `eclaw-update-conversation'.
Logs each HTTP exchange.  Empty string is returned if content is absent."
  (let* ((messages-1 (eclaw-build-messages prompt))
         (payload-1 (eclaw--chat-request-payload messages-1))
         (response-1 (eclaw--post-chat-completion payload-1))
         (tool-calls (eclaw-get-tool-calls response-1))
         (usage-1 (alist-get 'usage response-1)))
    (eclaw-log payload-1 response-1)
    (when usage-1 (eclaw-report-usage usage-1))
    (if (and tool-calls (> (length tool-calls) 0))
        (let* ((assistant-msg (eclaw-get-message response-1))
               (tool-id (eclaw--first-tool-call-id tool-calls))
               (result (eclaw--dispatch-one-tool-call (car tool-calls)))
               ;; Persist user + assistant (tool request) + tool result, then follow up.
               (_ (setq eclaw-conversation
                        (nconc eclaw-conversation
                               (list (eclaw-user-message prompt)
                                     assistant-msg
                                     (eclaw-tool-message tool-id result)))))
               (messages-2 (eclaw-build-messages-continuation))
               (payload-2 (eclaw--chat-request-payload messages-2))
               (response-2 (eclaw--post-chat-completion payload-2))
               (final-text (eclaw-get-content response-2))
               (usage-2 (alist-get 'usage response-2)))
          (eclaw-log payload-2 response-2)
          (when usage-2 (eclaw-report-usage usage-2))
          (setq eclaw-conversation
                (nconc eclaw-conversation
                       (list (eclaw-assistant-message (or final-text "")))))
          (or final-text ""))
      (let ((content (eclaw-get-content response-1)))
        (eclaw-update-conversation prompt content)
        (or content "")))))

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
