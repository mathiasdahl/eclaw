;;; smoke/eval-elisp.el — tool policy defaults and eval_elisp handler checks.

(setq eclaw-folder (make-temp-file "eclaw-smoke-eval-" t))

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

(defun smoke--eval-with-mode (mode code)
  (let ((eclaw-eval-safety-mode mode))
    (eclaw-tool-eval-elisp code)))

(let* ((tmpdir eclaw-folder))
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

  (smoke--assert "full mode evaluates code"
                 (string-equal "result=3" (smoke--eval-with-mode 'full "(+ 1 2)")))

  (smoke--assert "trailing input rejected"
                 (string-match-p "trailing input"
                                   (smoke--eval-with-mode 'full "(+ 1 2) (+ 3 4)")))

  (smoke--assert "restricted blocks shell-command"
                 (string-match-p "blocked call to `shell-command'"
                                   (smoke--eval-with-mode 'restricted
                                                          "(shell-command \"echo hi\")")))

  (smoke--assert "restricted allows defun"
                 (string-equal "result=1"
                               (smoke--eval-with-mode 'restricted
                                                      "(progn (defun smoke-restricted-f () 1) (smoke-restricted-f))")))

  (smoke--assert "restricted blocks nested shell"
                 (let ((result (smoke--eval-with-mode 'restricted
                                                    "(progn (defun smoke-nested-evil () (shell-command \"x\")) (smoke-nested-evil))")))
                   (or (string-match-p "blocked by eclaw eval safety" result)
                       (string-match-p "blocked call to `shell-command'" result))))

  (smoke--assert "strict rejects defun"
                 (string-match-p "strict"
                                   (smoke--eval-with-mode 'strict "(defun smoke-strict-f () 1)")))

  (smoke--assert "strict rejects shell-command"
                 (string-match-p "strict"
                                   (smoke--eval-with-mode 'strict "(shell-command \"echo hi\")")))

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
