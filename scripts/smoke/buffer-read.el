;;; smoke/buffer-read.el — exercise eclaw-tool-buffer-read edge cases.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke buffer-read FAIL: %s" label)))

(defun smoke--make-lines-buffer (name line-count)
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (dotimes (i line-count)
        (insert (format "line %d\n" (1+ i)))))
    buf))

(let ((big-buf (smoke--make-lines-buffer " eclaw-smoke-buffer-read-big" 300))
      (small-buf (smoke--make-lines-buffer " eclaw-smoke-buffer-read-small" 3))
      (auth-buf (generate-new-buffer "*auth*"))
      (current-result)
      (named-result)
      (slice-result)
      (tail-result)
      (beyond-result)
      (missing-result)
      (blocked-result))
  (with-current-buffer big-buf
    (setq current-result (eclaw-tool-buffer-read "current")))
  (smoke--assert "current buffer read has line numbers"
                 (string-match-p "^[[:space:]]*1|" current-result))
  (smoke--assert "current buffer read truncated at default limit"
                 (string-match-p "\\[eclaw: line limit 250 reached\\]" current-result))

  (setq named-result (eclaw-tool-buffer-read " eclaw-smoke-buffer-read-big"))
  (smoke--assert "named buffer read returns first line"
                 (string-match-p "1|line 1" named-result))

  (setq slice-result (eclaw-tool-buffer-read " eclaw-smoke-buffer-read-big" 100 5))
  (smoke--assert "offset/limit returns line 100"
                 (string-match-p "100|line 100" slice-result))
  (smoke--assert "offset/limit has no truncation footer"
                 (not (string-match-p "\\[eclaw: line limit" slice-result)))

  (setq tail-result (eclaw-tool-buffer-read " eclaw-smoke-buffer-read-small" -3 2))
  (smoke--assert "negative offset returns last lines"
                 (and (string-match-p "2|line 2" tail-result)
                      (string-match-p "3|line 3" tail-result)))

  (setq beyond-result (eclaw-tool-buffer-read " eclaw-smoke-buffer-read-small" 99))
  (smoke--assert "offset beyond EOF is error string"
                 (string-match-p "^Error: buffer_read offset" beyond-result))

  (setq missing-result (eclaw-tool-buffer-read " eclaw-smoke-buffer-read-missing"))
  (smoke--assert "missing buffer is error string"
                 (string-match-p "^Error: buffer_read: no live buffer" missing-result))

  (with-current-buffer auth-buf
    (insert "secret\n")
    (setq blocked-result (eclaw-tool-buffer-read "*auth*")))
  (smoke--assert "blocked buffer name denied"
                 (string-equal blocked-result eclaw--sensitive-buffer-msg))

  (kill-buffer big-buf)
  (kill-buffer small-buf)
  (kill-buffer auth-buf)
  (message "smoke buffer-read: OK"))
