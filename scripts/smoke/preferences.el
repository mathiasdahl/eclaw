;;; smoke/preferences.el — user preference memory in system message and tools.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke preferences FAIL: %s" label)))

(defun smoke--system-content ()
  (alist-get 'content (eclaw-system-message)))

(let ((orig-folder eclaw-folder)
      (tmpdir (make-temp-file "eclaw-prefs-smoke-" t))
      (prefs-file nil)
      (content-empty)
      (content-loaded)
      (content-stable)
      (content-trunc)
      (append-result)
      (write-result))
  (setq prefs-file (expand-file-name "preferences.md" tmpdir))
  (setq eclaw-folder (expand-file-name tmpdir))
  (eclaw--invalidate-preferences-cache)

  (setq content-empty (smoke--system-content))
  (smoke--assert "no preferences block when file missing"
                 (not (string-match-p "## User preferences" content-empty)))

  (with-temp-file prefs-file
    (insert "- Prefers concise answers\n- Timezone: Europe/Stockholm\n"))
  (eclaw--invalidate-preferences-cache)
  (setq content-loaded (smoke--system-content))
  (smoke--assert "preferences block present"
                 (string-match-p "## User preferences" content-loaded))
  (smoke--assert "bullet content injected"
                 (and (string-match-p "Prefers concise answers" content-loaded)
                      (string-match-p "Timezone: Europe/Stockholm" content-loaded)))

  (setq content-stable (smoke--system-content))
  (smoke--assert "system message stable across calls"
                 (string-equal content-loaded content-stable))

  (let ((long-line (make-string (+ eclaw-preferences-max-chars 200) ?x)))
    (with-temp-file prefs-file
      (insert long-line))
    (eclaw--invalidate-preferences-cache)
    (setq content-trunc (smoke--system-content))
    (smoke--assert "truncation notice when over cap"
                   (string-match-p "truncated; [0-9]+ chars omitted" content-trunc)))

  (delete-file prefs-file)
  (eclaw--invalidate-preferences-cache)

  (setq append-result (eclaw-tool-preferences-append "Uses Emacs daily"))
  (smoke--assert "preferences_append succeeds"
                 (string-match-p "Preferences saved" append-result))
  (smoke--assert "preferences_append wrote bullet"
                 (with-temp-buffer
                   (insert-file-contents-literally prefs-file)
                   (string-match-p "- Uses Emacs daily" (buffer-string))))

  (setq write-result (eclaw-tool-preferences-write "- One line only\n"))
  (smoke--assert "preferences_write succeeds"
                 (string-match-p "Preferences saved" write-result))
  (smoke--assert "preferences_write replaced content"
                 (with-temp-buffer
                   (insert-file-contents-literally prefs-file)
                   (string-equal "- One line only\n" (buffer-string))))

  (setq eclaw-folder orig-folder)
  (eclaw--invalidate-preferences-cache)
  (delete-directory tmpdir t)
  (message "smoke preferences: OK"))
