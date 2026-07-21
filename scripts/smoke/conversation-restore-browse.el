;;; smoke/conversation-restore-browse.el — pristine restore switch and in-place update.

(require 'json)
(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke conversation-restore-browse FAIL: %s" label)))

(let* ((json-object-type 'alist)
       (json-array-type 'list)
       (json-key-type 'symbol)
       (tmpdir (make-temp-file "eclaw-smoke-restore-browse-" t))
       (archive-a-messages
        (list (eclaw-user-message "archive A prompt")))
       (archive-b-messages
        (list (eclaw-user-message "archive B prompt")))
       (archives)
       (file-a)
       (file-b)
       (snapshot-b))
  (setq eclaw-folder tmpdir)
  (setq eclaw-conversation archive-a-messages)
  (setq eclaw--session-started (encode-time 0 0 10 21 6 2026))
  (eclaw-reset-conversation)
  (setq eclaw-conversation archive-b-messages)
  (setq eclaw--session-started (encode-time 0 0 11 21 6 2026))
  (eclaw-reset-conversation)
  (setq archives (eclaw-list-archived-conversations))
  (smoke--assert "two archived conversations" (= 2 (length archives)))
  (setq file-a (plist-get (nth 1 archives) 'file))
  (setq file-b (plist-get (nth 0 archives) 'file))
  (eclaw-restore-conversation file-a)
  (smoke--assert "restored from file A"
                 (equal file-a eclaw--restored-from-file))
  (smoke--assert "restored session not dirty" (not eclaw--session-dirty-p))
  (eclaw-restore-conversation file-b)
  (smoke--assert "browse restore creates no duplicate"
                 (= 2 (length (eclaw-list-archived-conversations))))
  (smoke--assert "now restored from file B"
                 (equal file-b eclaw--restored-from-file))
  (setq eclaw-conversation
        (append eclaw-conversation (list (eclaw-user-message "continued turn"))))
  (setq eclaw--session-dirty-p t)
  (eclaw-reset-conversation)
  (smoke--assert "continued restore still one archive pair per chat"
                 (= 2 (length (eclaw-list-archived-conversations))))
  (setq snapshot-b
        (eclaw--conversation-read-snapshot
         (expand-file-name file-b (eclaw--conversation-archive-dir))))
  (smoke--assert "continued restore updated archive B in place"
                 (= 2 (eclaw--snapshot-turn-count (alist-get 'messages snapshot-b))))
  (delete-directory tmpdir t)
  (message "smoke conversation-restore-browse: OK"))
