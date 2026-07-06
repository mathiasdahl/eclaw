;;; smoke/eval-elisp.el — tool policy defaults and eval_elisp handler checks.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke eval-elisp FAIL: %s" label)))

(defun smoke--tool-in-definitions-p (name)
  (let ((defs (eclaw-tool-definitions)))
    (cl-some
     (lambda (entry)
       (let ((fn (cdr (assoc 'function entry))))
         (and fn (string= name (cdr (assoc 'name fn))))))
     defs)))

(let* ((tmpdir (make-temp-file "eclaw-smoke-eval-" t)))
  (setq eclaw-folder tmpdir)
  (setq eclaw--tool-policy-loaded nil)
  (setq eclaw--tool-policy nil)

  (smoke--assert "eclaw-eval feature loaded"
                 (featurep 'eclaw-eval))

  (smoke--assert "eval_elisp registered"
                 (gethash "eval_elisp" eclaw--tool-registry))

  (let ((info (gethash "eval_elisp" eclaw--tool-registry)))
    (smoke--assert "eval_elisp tagged :dangerous"
                   (eq (plist-get info :risk) :dangerous)))

  (smoke--assert "eval_elisp disabled by default"
                 (not (eclaw-tool-policy-enabled-p "eval_elisp")))

  (smoke--assert "eval_elisp absent from API tools by default"
                 (not (smoke--tool-in-definitions-p "eval_elisp")))

  (eclaw-tool-policy-set "eval_elisp" t)

  (smoke--assert "eval_elisp enabled after policy set"
                 (eclaw-tool-policy-enabled-p "eval_elisp"))

  (smoke--assert "eval_elisp advertised after enable"
                 (smoke--tool-in-definitions-p "eval_elisp"))

  (smoke--assert "eval_elisp evaluates code"
                 (string-equal "result=3" (eclaw-tool-eval-elisp "(+ 1 2)")))

  (eclaw-tool-policy-set "eval_elisp" nil)

  (smoke--assert "disabled dispatch message"
                 (string-equal
                  eclaw--tool-policy-disabled-msg
                  (eclaw--dispatch-one-tool-call
                   '((id . "smoke-1")
                     (function . ((name . "eval_elisp")
                                    (arguments . "{\"code\":\"(+ 1 2)\"}")))))))

  (delete-directory tmpdir t)
  (message "smoke eval-elisp: OK"))
