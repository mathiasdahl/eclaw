;;; smoke/session-context.el — session date block in system message.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke session-context FAIL: %s" label)))

(defun smoke--system-content ()
  (alist-get 'content (eclaw-system-message)))

(let* ((time1 (encode-time 0 32 14 7 6 2026))
       (time1-same-day (encode-time 0 30 17 7 6 2026))
       (time2 (encode-time 0 0 9 1 1 2027))
       (expected1 (format-time-string "%A, %Y-%m-%d %Z" time1))
       (expected2 (format-time-string "%A, %Y-%m-%d %Z" time2))
       (content1)
       (content2)
       (content-same-day)
       (content-after-reset))
  (setq eclaw--session-started time1)
  (setq content1 (smoke--system-content))
  (smoke--assert "session context prefix present"
                 (string-match-p "Session context: today is" content1))
  (smoke--assert "formatted session date present"
                 (string-match-p (regexp-quote expected1) content1))
  (smoke--assert "time of day not in session block"
                 (not (string-match-p "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" content1)))
  (smoke--assert "training cutoff guidance present"
                 (string-match-p "not your training cutoff" content1))
  (smoke--assert "get_datetime guidance present"
                 (string-match-p "get_datetime" content1))

  (setq content2 (smoke--system-content))
  (smoke--assert "system message stable across calls"
                 (string-equal content1 content2))

  (setq eclaw--session-started time1-same-day)
  (setq content-same-day (smoke--system-content))
  (smoke--assert "same calendar day yields identical session block"
                 (string-equal content1 content-same-day))

  (eclaw-reset-conversation)
  (smoke--assert "session cleared after reset"
                 (null eclaw--session-started))
  (smoke--assert "no session block when session unset"
                 (not (string-match-p "Session context:" (smoke--system-content))))

  (setq eclaw--session-started time2)
  (setq content-after-reset (smoke--system-content))
  (smoke--assert "new session date reflected"
                 (string-match-p (regexp-quote expected2) content-after-reset))
  (smoke--assert "content differs from first session"
                 (not (string-equal content1 content-after-reset)))

  (setq eclaw--session-started nil)
  (message "smoke session-context: OK"))
