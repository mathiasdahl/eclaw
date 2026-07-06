;;; smoke/send-email.el — offline recipient policy and mailme-mail integration checks.

(require 'eclaw)

(defvar smoke-mail--calls nil
  "List of (body address) calls captured by the smoke stub.")

(defun mailme-mail (body address)
  "Smoke stub for `mailme-mail'."
  (push (list body address) smoke-mail--calls))

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke send-email FAIL: %s" label)))

(smoke--assert "eclaw-mail feature loaded"
               (featurep 'eclaw-mail))

(when eclaw-mail-enabled
  (smoke--assert "send_email enabled in policy by default"
                 (eclaw-tool-policy-enabled-p "send_email")))

(smoke--assert "send_email registered"
               (gethash "send_email" eclaw--tool-registry))

(let ((info (gethash "send_email" eclaw--tool-registry)))
  (smoke--assert "send_email tagged :write"
                 (eq (plist-get info :risk) :write)))

(smoke--assert "invalid recipient rejected"
               (string-match-p "recipient must be work or home"
                               (eclaw-mail-send "other" "Hi" "Body")))

(smoke--assert "empty subject rejected"
               (string-match-p "requires non-empty subject"
                               (eclaw-mail-send "work" "  " "Body")))

(smoke--assert "empty body rejected"
               (string-match-p "requires non-empty body"
                               (eclaw-mail-send "work" "Hi" "")))

(let ((eclaw-mail-work-address nil)
      (eclaw-mail-home-address nil))
  (smoke--assert "unset work address rejected"
                 (string-match-p "address for work is not configured"
                                 (eclaw-mail-send "work" "Hi" "Body"))))

(let ((eclaw-mail-work-address "work@example.com")
      (eclaw-mail-home-address "home@example.com")
      smoke-mail--calls)
  (setq smoke-mail--calls nil)
  (let ((result (eclaw-mail-send "Work" "Subject line" "Hello there")))
    (smoke--assert "send to work succeeds"
                   (string-match-p "Email sent to work" result))
    (smoke--assert "mailme-mail called once"
                   (= 1 (length smoke-mail--calls)))
    (let ((call (car smoke-mail--calls)))
      (smoke--assert "mailme-mail uses work address"
                     (string-equal "work@example.com" (cadr call)))
      (smoke--assert "mailme-mail body includes subject"
                     (string-equal "Subject: Subject line\n\nHello there"
                                   (car call))))))

(let ((eclaw-mail-work-address "work@example.com")
      (eclaw-mail-home-address "home@example.com")
      smoke-mail--calls)
  (setq smoke-mail--calls nil)
  (let ((result (eclaw-mail-send "home" "Home subj" "Home body")))
    (smoke--assert "send to home succeeds"
                   (string-match-p "Email sent to home" result))
    (smoke--assert "mailme-mail home address"
                   (string-equal "home@example.com"
                                 (cadr (car smoke-mail--calls))))))

(message "smoke send-email: OK")
