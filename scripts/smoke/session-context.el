;;; smoke/session-context.el — session datetime block in system message.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke session-context FAIL: %s" label)))

(defun smoke--system-content ()
  (alist-get 'content (eclaw-system-message)))

(let* ((time1 (encode-time 0 32 14 7 6 2026))
       (time2 (encode-time 0 0 9 1 1 2027))
       (expected1 (format-time-string "%A, %Y-%m-%d %H:%M:%S %Z" time1))
       (expected2 (format-time-string "%A, %Y-%m-%d %H:%M:%S %Z" time2))
       (content1)
       (content2)
       (content3)
       (content-after-reset))
  (setq eclaw--session-started time1)
  (setq content1 (smoke--system-content))
  (smoke--assert "session context prefix present"
                 (string-match-p "Session context: started" content1))
  (smoke--assert "formatted session start present"
                 (string-match-p (regexp-quote expected1) content1))
  (smoke--assert "training cutoff guidance present"
                 (string-match-p "not your training cutoff" content1))

  (setq content2 (smoke--system-content))
  (smoke--assert "system message stable across calls"
                 (string-equal content1 content2))

  (eclaw-reset-conversation)
  (smoke--assert "session cleared after reset"
                 (null eclaw--session-started))
  (smoke--assert "no session block when session unset"
                 (not (string-match-p "Session context:" (smoke--system-content))))

  (setq eclaw--session-started time2)
  (setq content-after-reset (smoke--system-content))
  (smoke--assert "new session time reflected"
                 (string-match-p (regexp-quote expected2) content-after-reset))
  (smoke--assert "content differs from first session"
                 (not (string-equal content1 content-after-reset)))

  (setq eclaw--session-started nil)
  (message "smoke session-context: OK"))
