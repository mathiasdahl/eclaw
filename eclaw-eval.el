;;; eclaw-eval.el --- Runtime Elisp evaluation tool for eclaw  -*- lexical-binding: nil -*-

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
;; `eval_elisp' tool: full Elisp evaluation in the running Emacs session.
;; Disabled by default via `tool-policy.el' (see `eclaw-tool-policy-enabled-p').
;;

;;; Code:

(require 'subr-x)
(require 'eclaw-tools)

(defgroup eclaw-eval nil
  "Runtime Elisp evaluation tool for eclaw."
  :group 'eclaw)

(defcustom eclaw-eval-timeout-seconds 30
  "Maximum seconds allowed for one `eval_elisp' tool call."
  :type 'integer
  :group 'eclaw-eval)

(defconst eclaw-eval-max-code-length 32768
  "Maximum byte length of `code' accepted by `eval_elisp'.")

(defun eclaw-tool-eval-elisp (code)
  "Evaluate CODE as Elisp in the running Emacs session; return result text.
Uses `(eval form t)' with `with-timeout'.  Multi-form bodies should use
`(progn ...)'.  Side effects apply immediately when policy allows the tool."
  (let ((text (or code "")))
    (cond
     ((string-empty-p (string-trim text))
      "Error: eval_elisp requires non-empty \"code\" in arguments.")
     ((> (length text) eclaw-eval-max-code-length)
      (format "Error: eval_elisp code exceeds max length (%d bytes)."
              eclaw-eval-max-code-length))
     (t
      (condition-case err
          (condition-case timeout
              (let* ((read-result (read-from-string text))
                     (form (car read-result))
                     (value
                      (with-timeout (eclaw-eval-timeout-seconds)
                        (eval form t))))
                (format "result=%s" (prin1-to-string value)))
            (timeout
             (format "Error: eval_elisp timed out after %d seconds."
                     eclaw-eval-timeout-seconds)))
        (error
         (format "Error: eval_elisp failed: %S" err)))))))

(eclaw-deftool eval_elisp
  "Evaluate Elisp in the running Emacs session. Side effects apply immediately (define functions, set variables, require files, modify buffers). Disabled unless enabled in tool policy. Use (progn ...) for multiple forms."
  ((code :string "Elisp expression or progn body to evaluate."))
  (:risk :dangerous)
  (eclaw-tool-eval-elisp code))

(provide 'eclaw-eval)
;;; eclaw-eval.el ends here
