;;; smoke/conversation-snapshot-write.el — archive writes JSON snapshot with messages.

(require 'json)
(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke conversation-snapshot-write FAIL: %s" label)))

(let* ((json-object-type 'alist)
       (json-array-type 'list)
       (json-key-type 'string)
       (tmpdir (make-temp-file "eclaw-smoke-snapshot-" t))
       (tool-call-id "call_smoke_read_file")
       (assistant-with-tools
        `((role . "assistant")
          (content . "")
          (tool_calls . (((id . ,tool-call-id)
                          (type . "function")
                          (function . ((name . "read_file")
                                       (arguments . "{\"path\":\"/tmp/smoke.txt\"}"))))))))
       (original-messages
        (list (eclaw-user-message "run read_file on smoke fixture")
              assistant-with-tools
              (eclaw-tool-message tool-call-id "smoke file contents")
              (eclaw-assistant-message "Hi! 👋 The file contains smoke test data.")))
       (md-path)
       (json-path)
       (snapshot)
       (read-messages))
  (setq eclaw-folder tmpdir)
  (setq eclaw--session-started (encode-time 0 0 12 21 6 2026))
  (setq eclaw--usage-conversation '((prompt_tokens . 42) (completion_tokens . 17)))
  (setq eclaw-conversation original-messages)
  (setq md-path (eclaw-archive-current-conversation))
  (smoke--assert "archive path returned" md-path)
  (smoke--assert "markdown archive exists" (file-regular-p md-path))
  (setq json-path (concat (file-name-sans-extension md-path) ".json"))
  (smoke--assert "json snapshot exists" (file-regular-p json-path))
  (setq snapshot (eclaw--conversation-read-snapshot json-path))
  (smoke--assert "snapshot version is 1" (= 1 (alist-get 'version snapshot)))
  (setq read-messages (alist-get 'messages snapshot))
  (smoke--assert "snapshot messages is a list" (listp read-messages))
  (smoke--assert "messages round-trip via snapshot read"
                 (equal original-messages read-messages))
  (smoke--assert "emoji preserved as multibyte"
                 (let ((content (alist-get 'content (nth 3 read-messages))))
                   (and (multibyte-string-p content)
                        (string-match-p "👋" content))))
  (delete-directory tmpdir t)
  (message "smoke conversation-snapshot-write: OK"))
