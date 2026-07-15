;;; eclaw-preferences.el --- User preference memory for eclaw  -*- lexical-binding: nil -*-

;; Copyright (C) 2026-2026  Mathias Dahl

;; Author: Mathias Dahl <mathias.dahl@gmail.com>
;; Maintainer: Mathias Dahl <mathias.dahl@gmail.com>

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;;
;; Loads `preferences.md' under `eclaw-folder', mtime-based cache, and the
;; user-preferences block appended to the system message.
;;

;;; Code:

;; Runtime: `eclaw' loads this before `eclaw-system-message'.
(declare-function eclaw-debug-message "eclaw" (format-string &rest args))
(declare-function eclaw--folder "eclaw" ())

(defvar eclaw-folder)

(defgroup eclaw-preferences nil
  "User preference memory for eclaw."
  :group 'eclaw)

(defcustom eclaw-preferences-max-chars 2048
  "Maximum characters injected from or written to `preferences.md'.
Content beyond this limit is truncated on inject and rejected on write."
  :type 'integer
  :group 'eclaw-preferences)

(defvar eclaw--preferences-cache nil
  "Internal plist used by `eclaw--preferences-cached-content'.
Keys are :file (string path), :mtime (float), :content (string).")

(defun eclaw--preferences-file ()
  "Return absolute path to `preferences.md' under `eclaw-folder'."
  (expand-file-name "preferences.md" (eclaw--folder)))

(defun eclaw--preferences-load ()
  "Read `preferences.md' from disk.
Return plist (:file :mtime :content) when the file exists and is non-empty
after trim, else nil."
  (let ((file (eclaw--preferences-file)))
    (when (and (file-regular-p file)
               (not (zerop (nth 7 (file-attributes file)))))
      (let ((content (with-temp-buffer
                       (insert-file-contents-literally file)
                       (set-buffer-multibyte t)
                       (buffer-string))))
        (let ((trimmed (string-trim content)))
          (when (not (string-empty-p trimmed))
            (list :file file
                  :mtime (float-time (file-attribute-modification-time
                                      (file-attributes file)))
                  :content trimmed)))))))

(defun eclaw--preferences-cached-content ()
  "Return trimmed `preferences.md' content, using `eclaw--preferences-cache'."
  (let ((file (eclaw--preferences-file)))
    (if (not (file-regular-p file))
        nil
      (let* ((mtime (float-time (file-attribute-modification-time
                                 (file-attributes file))))
             (cached eclaw--preferences-cache))
        (if (and cached
                 (equal file (plist-get cached :file))
                 (equal mtime (plist-get cached :mtime)))
            (plist-get cached :content)
          (when-let ((loaded (eclaw--preferences-load)))
            (setq eclaw--preferences-cache loaded)
            (eclaw-debug-message "eclaw: preferences loaded from %s" file)
            (plist-get loaded :content)))))))

(defun eclaw--preferences-truncate-for-inject (content)
  "Return CONTENT trimmed to `eclaw-preferences-max-chars' for system inject.
When truncated, append a one-line notice with the number of omitted chars."
  (let* ((max eclaw-preferences-max-chars)
         (len (length content)))
    (if (<= len max)
        content
      (let* ((notice (format "\n\n(truncated; %d chars omitted)" (- len max)))
             (budget (- max (length notice))))
        (concat (substring content 0 (max 0 budget)) notice)))))

(defun eclaw--invalidate-preferences-cache ()
  "Clear `eclaw--preferences-cache' so the next read reloads from disk."
  (setq eclaw--preferences-cache nil))

(defun eclaw--preferences-system-block ()
  "Return user preferences text for the system prompt, or \"\"."
  (if-let ((content (eclaw--preferences-cached-content)))
      (concat "\n\n## User preferences\n\n"
              "Short snippets about the user, stored across sessions. "
              "Use `preferences_append' to add and `preferences_write' to replace.\n\n"
              (eclaw--preferences-truncate-for-inject content))
    ""))

(provide 'eclaw-preferences)
;;; eclaw-preferences.el ends here
