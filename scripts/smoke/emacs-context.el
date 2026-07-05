;;; smoke/emacs-context.el — exercise eclaw-tool-emacs-context.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke emacs-context FAIL: %s" label)))

(let ((ctx-buf (generate-new-buffer " eclaw-smoke-emacs-context"))
      (extra-buf (generate-new-buffer " eclaw-smoke-emacs-context-extra"))
      (auth-buf (generate-new-buffer "*auth*"))
      (result)
      (trunc-result))
  (with-current-buffer ctx-buf
    (fundamental-mode)
    (insert "hello\n")
    (setq result (eclaw-tool-emacs-context)))

  (smoke--assert "Emacs version line present"
                 (string-match-p "^Emacs " result))
  (smoke--assert "Session started line present"
                 (string-match-p "^Session started: " result))
  (smoke--assert "Current buffer section present"
                 (string-match-p "Current buffer:" result))
  (smoke--assert "Current buffer name present"
                 (string-match-p "name:  eclaw-smoke-emacs-context" result))
  (smoke--assert "Current buffer mode present"
                 (string-match-p "mode: fundamental-mode" result))
  (smoke--assert "Open buffers header present"
                 (string-match-p "Open buffers (" result))
  (smoke--assert "Sensitive buffer omitted from listing"
                 (not (string-match-p "\\*auth\\*" result)))

  (setq trunc-result (eclaw-tool-emacs-context 1))
  (smoke--assert "max_buffers truncation footer"
                 (string-match-p "\\[eclaw: listing truncated to 1 entr" trunc-result))

  (kill-buffer ctx-buf)
  (kill-buffer extra-buf)
  (kill-buffer auth-buf)
  (message "smoke emacs-context: OK"))
