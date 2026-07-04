;;; smoke/read-file.el — exercise eclaw-tool-read-file edge cases.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke read-file FAIL: %s" label)))

(defun smoke--write-lines-file (path line-count)
  (with-temp-buffer
    (dotimes (i line-count)
      (insert (format "line %d\n" (1+ i))))
    (write-region (point-min) (point-max) path)))

(let* ((tmpdir (make-temp-file "eclaw-smoke-read-" t))
       (big-file (expand-file-name "big.txt" tmpdir))
       (small-file (expand-file-name "small.txt" tmpdir))
       (sensitive (expand-file-name "id_rsa" (expand-file-name ".ssh" "~")))
       (full-result)
       (slice-result)
       (tail-result)
       (beyond-result)
       (sensitive-result)
       (outside-result))
  (setq eclaw-folder tmpdir)
  (smoke--write-lines-file big-file 300)
  (smoke--write-lines-file small-file 3)

  (setq full-result (eclaw-tool-read-file big-file))
  (smoke--assert "full read has line numbers"
                 (string-match-p "^[[:space:]]*1|" full-result))
  (smoke--assert "full read truncated at default limit"
                 (string-match-p "\\[eclaw: line limit 250 reached\\]" full-result))

  (setq slice-result (eclaw-tool-read-file big-file 100 5))
  (smoke--assert "offset/limit returns line 100"
                 (string-match-p "100|line 100" slice-result))
  (smoke--assert "offset/limit has no truncation footer"
                 (not (string-match-p "\\[eclaw: line limit" slice-result)))

  (setq tail-result (eclaw-tool-read-file small-file -3 2))
  (smoke--assert "negative offset returns last lines"
                 (and (string-match-p "2|line 2" tail-result)
                      (string-match-p "3|line 3" tail-result)))

  (setq beyond-result (eclaw-tool-read-file small-file 99))
  (smoke--assert "offset beyond EOF is error string"
                 (string-match-p "^Error: read_file offset" beyond-result))

  (setq outside-result (eclaw-tool-read-file "/etc/passwd"))
  (smoke--assert "path outside eclaw-folder denied"
                 (string-equal outside-result eclaw--tool-path-outside-folder-msg))

  (when (file-exists-p sensitive)
    (setq sensitive-result (eclaw-tool-read-file sensitive))
    (smoke--assert "sensitive path outside eclaw-folder uses folder guard"
                   (string-equal sensitive-result eclaw--tool-path-outside-folder-msg)))

  (delete-directory tmpdir t)
  (message "smoke read-file: OK"))
