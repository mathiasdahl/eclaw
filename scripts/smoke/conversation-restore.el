;;; smoke/conversation-restore.el — archive, reset, restore roundtrip.

(require 'json)
(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke conversation-restore FAIL: %s" label)))

(let* ((json-object-type 'alist)
       (json-array-type 'list)
       (json-key-type 'symbol)
       (tmpdir (make-temp-file "eclaw-smoke-restore-" t))
       (tool-call-id "call_smoke_read_file")
       (assistant-with-tools
        `((role . "assistant")
          (content . "")
          (tool_calls . (((id . ,tool-call-id)
                          (type . "function")
                          (function . ((name . "read_file")
                                       (arguments . "{\"path\":\"/tmp/smoke.txt\"}"))))))))
       (emoji-reply "Hi! 👋 The file contains smoke test data.")
       (original-messages
        (list (eclaw-user-message "run read_file on smoke fixture")
              assistant-with-tools
              (eclaw-tool-message tool-call-id "smoke file contents")
              (eclaw-assistant-message emoji-reply)))
       (original-session-started (encode-time 0 0 12 21 6 2026))
       (archives)
       (json-basename))
  (setq eclaw-folder tmpdir)
  (setq eclaw--session-started original-session-started)
  (setq eclaw--usage-conversation '((prompt_tokens . 42) (completion_tokens . 17)))
  (setq eclaw-conversation original-messages)
  (eclaw-reset-conversation)
  (smoke--assert "session empty after reset"
                 (and (null eclaw-conversation) (null eclaw--session-started)))
  (setq archives (eclaw-list-archived-conversations))
  (smoke--assert "one archived conversation" (= 1 (length archives)))
  (setq json-basename (plist-get (car archives) 'file))
  (smoke--assert "snapshot basename present" json-basename)
  (eclaw-restore-conversation json-basename)
  (smoke--assert "messages restored"
                 (equal original-messages eclaw-conversation))
  (smoke--assert "emoji preserved as multibyte"
                 (let ((content (alist-get 'content (nth 3 eclaw-conversation))))
                   (and (multibyte-string-p content)
                        (string= content emoji-reply))))
  (smoke--assert "session-started restored"
                 (equal (eclaw--parse-iso-timestamp
                         (eclaw--iso-timestamp original-session-started))
                        eclaw--session-started))
  (delete-directory tmpdir t)
  (message "smoke conversation-restore: OK"))
