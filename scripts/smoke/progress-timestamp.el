;;; smoke/progress-timestamp.el — ISO timestamp helper for eclaw messages.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke progress-timestamp FAIL: %s" label)))

(let* ((time (encode-time 45 9 15 3 7 2026))
       (expected (format-time-string "%Y-%m-%dT%H:%M:%S%z" time))
       (actual (eclaw--iso-timestamp time)))
  (smoke--assert "fixed-time ISO timestamp"
                 (string-equal actual expected))
  (smoke--assert "timestamp matches ISO pattern"
                 (string-match-p
                  "\\`[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]\\'"
                  actual))
  (message "smoke progress-timestamp: OK"))
