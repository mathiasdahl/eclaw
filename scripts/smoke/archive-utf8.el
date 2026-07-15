;;; smoke/archive-utf8.el — conversation archive writes UTF-8 without prompting.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke archive-utf8 FAIL: %s" label)))

(let* ((tmpdir (make-temp-file "eclaw-smoke-archive-" t))
       (non-ascii "café 你好")
       (path))
  (setq eclaw-folder tmpdir)
  (setq eclaw-conversation (list (eclaw-user-message non-ascii)))
  (with-current-buffer (get-buffer-create "*eclaw*")
    (erase-buffer)
    (insert non-ascii))
  (setq path (eclaw-archive-current-conversation))
  (smoke--assert "archive path returned" path)
  (smoke--assert "archive file exists" (file-regular-p path))
  (let ((content (with-temp-buffer
                   (set-buffer-file-coding-system 'utf-8-unix)
                   (insert-file-contents-literally path)
                   (decode-coding-region (point-min) (point-max) 'utf-8-unix)
                   (buffer-string))))
    (smoke--assert "non-ascii text preserved in archive"
                   (string-match-p (regexp-quote non-ascii) content)))
  (delete-directory tmpdir t)
  (message "smoke archive-utf8: OK"))
