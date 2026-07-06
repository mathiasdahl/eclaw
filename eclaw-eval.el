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
;; See `docs/eval-elisp-security.md' for the trust model and safety modes.
;;

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eclaw-tools)

(defgroup eclaw-eval nil
  "Runtime Elisp evaluation tool for eclaw."
  :group 'eclaw)

(defcustom eclaw-eval-safety-mode 'full
  "How strictly `eval_elisp' guards parsed Elisp before evaluation.

`full' — no content guards (full session access once policy allows).

`restricted' — static denylist on the parsed form plus runtime stubs on
high-impact functions; still allows `defun', `setq', `require', and buffers.

`strict' — reject forms Emacs `unsafep' considers unsafe (compute-oriented).

See `docs/eval-elisp-security.md'."
  :type '(choice (const :tag "Full (no content guards)" full)
                 (const :tag "Restricted (denylist + stubs)" restricted)
                 (const :tag "Strict (unsafep)" strict))
  :group 'eclaw-eval)

(defcustom eclaw-eval-timeout-seconds 30
  "Maximum seconds allowed for one `eval_elisp' tool call."
  :type 'integer
  :group 'eclaw-eval)

(defconst eclaw-eval-max-code-length 32768
  "Maximum byte length of `code' accepted by `eval_elisp'.")

(defconst eclaw-eval--tier1-blocked-symbols
  '(shell-command async-shell-command call-process start-process make-process
    open-network-stream delete-file delete-directory kill-emacs load eval
    byte-compile)
  "High-impact functions blocked in `restricted' mode (static analysis).")

(defconst eclaw-eval--tier1-stub-symbols
  '(shell-command async-shell-command call-process start-process make-process
    open-network-stream delete-file delete-directory kill-emacs byte-compile)
  "Tier-1 symbols rebound during `restricted' eval.
Excludes `load' and `eval' so `require' and `defun' keep working; those
names remain blocked by static analysis only.")

(defconst eclaw-eval--tier2-blocked-symbols
  '(funcall apply intern symbol-function fset defalias advice-add advice-remove put)
  "Indirection helpers blocked in `restricted' mode (static only).")

(defun eclaw-eval--blocked (&rest _args)
  "Stub installed on dangerous functions during `restricted' eval."
  (error "eval_elisp: call blocked by eclaw eval safety (restricted mode)"))

(defun eclaw-eval--read-consumed-p (read-result source)
  "Non-nil when READ-RESULT consumed all meaningful input in SOURCE."
  (let ((pos (cdr read-result)))
    (or (not (integerp pos))
        (string-empty-p (string-trim (substring source pos))))))

(defun eclaw-eval--walk-subforms (form fn)
  "Call FN on FORM and each nested subform of FORM."
  (funcall fn form)
  (cond
   ((consp form)
    (let ((tail form))
      (while (consp tail)
        (eclaw-eval--walk-subforms (car tail) fn)
        (setq tail (cdr tail)))))
   ((vectorp form)
    (dotimes (i (length form))
      (eclaw-eval--walk-subforms (aref form i) fn)))))

(defun eclaw-eval--restricted-blocked-symbol-p (form)
  "Return blocked symbol when FORM violates restricted policy, else nil."
  (catch 'eclaw-eval-blocked
    (eclaw-eval--walk-subforms
     form
     (lambda (sub)
       (when (consp sub)
         (let ((head (car sub)))
           (when (symbolp head)
             (when (memq head eclaw-eval--tier1-blocked-symbols)
               (throw 'eclaw-eval-blocked head))
             (when (memq head eclaw-eval--tier2-blocked-symbols)
               (throw 'eclaw-eval-blocked head)))
           (when (memq head '(apply funcall))
             (let ((fn (nth 1 sub)))
               (when (and (symbolp fn)
                          (memq fn eclaw-eval--tier1-blocked-symbols))
                 (throw 'eclaw-eval-blocked fn))))))))
    nil))

(defun eclaw-eval--preflight-error (form)
  "Return an error string when FORM fails `eclaw-eval-safety-mode', else nil."
  (pcase eclaw-eval-safety-mode
    ('full nil)
    ('strict
     (let ((reason (unsafep form)))
       (when reason
         (format "Error: eval_elisp rejected (strict): %S" reason))))
    ('restricted
     (let ((blocked (eclaw-eval--restricted-blocked-symbol-p form)))
       (when blocked
         (format "Error: eval_elisp blocked call to `%s' (restricted)."
                 blocked))))))

(defun eclaw-eval--stub-bindings ()
  "Return `cl-letf' bindings that stub `eclaw-eval--tier1-stub-symbols'."
  (mapcar (lambda (sym)
            `((symbol-function ',sym) #'eclaw-eval--blocked))
          eclaw-eval--tier1-stub-symbols))

(defun eclaw-eval--eval-form (form)
  "Evaluate parsed FORM according to `eclaw-eval-safety-mode'."
  (pcase eclaw-eval-safety-mode
    ('full
     (eval form t))
    ('strict
     (eval form t))
    ('restricted
     (eval `(cl-letf ,(eclaw-eval--stub-bindings)
              (progn ,form))
           t))))

(defun eclaw-tool-eval-elisp (code)
  "Evaluate CODE as Elisp in the running Emacs session; return result text.
Uses `(eval form t)' with `with-timeout'.  Multi-form bodies should use
`(progn ...)'.  Side effects apply when policy allows.  See
`docs/eval-elisp-security.md' and `eclaw-eval-safety-mode'."
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
                     (preflight
                      (or (unless (eclaw-eval--read-consumed-p read-result text)
                            "Error: eval_elisp: trailing input after first form.")
                          (eclaw-eval--preflight-error form))))
                (if preflight
                    preflight
                  (format "result=%s"
                          (prin1-to-string
                           (with-timeout (eclaw-eval-timeout-seconds)
                             (eclaw-eval--eval-form form))))))
            (timeout
             (format "Error: eval_elisp timed out after %d seconds."
                     eclaw-eval-timeout-seconds)))
        (error
         (format "Error: eval_elisp failed: %S" err)))))))

(eclaw-deftool eval_elisp
  "Evaluate Elisp in the running Emacs session. Side effects apply immediately (define functions, set variables, require files, modify buffers). Disabled unless enabled in tool policy. Not a sandbox — see docs/eval-elisp-security.md. Use (progn ...) for multiple forms."
  ((code :string "Elisp expression or progn body to evaluate."))
  (:risk :dangerous)
  (eclaw-tool-eval-elisp code))

(provide 'eclaw-eval)
;;; eclaw-eval.el ends here
