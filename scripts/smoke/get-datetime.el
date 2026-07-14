;;; smoke/get-datetime.el — get_datetime tool output.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke get-datetime FAIL: %s" label)))

(let* ((session-time (encode-time 5 9 15 14 7 2026))
       (session-iso (eclaw--iso-timestamp session-time))
       (result))
  (setq eclaw--session-started session-time)
  (setq result (eclaw-tool-get-datetime))
  (smoke--assert "now line present"
                 (string-match-p "^now: " result))
  (smoke--assert "session_started line present"
                 (string-match-p (format "session_started: %s"
                                         (regexp-quote session-iso))
                                 result))
  (smoke--assert "now includes time of day"
                 (string-match-p "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" result))

  (setq eclaw--session-started nil)
  (setq result (eclaw-tool-get-datetime))
  (smoke--assert "now line present without session"
                 (string-match-p "^now: " result))
  (smoke--assert "session_started omitted without session"
                 (not (string-match-p "session_started:" result)))

  (message "smoke get-datetime: OK"))
