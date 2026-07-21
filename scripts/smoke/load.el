;;; smoke/load.el — require eclaw and basic feature checks.

(require 'eclaw)

(unless (featurep 'eclaw-http)
  (error "smoke load: eclaw-http feature missing"))

(unless (featurep 'eclaw-tools)
  (error "smoke load: eclaw-tools feature missing"))

(unless (featurep 'eclaw-web-search)
  (error "smoke load: eclaw-web-search feature missing"))

(unless (featurep 'eclaw-mail)
  (error "smoke load: eclaw-mail feature missing"))

(unless (featurep 'eclaw-eval)
  (error "smoke load: eclaw-eval feature missing"))

(unless (featurep 'eclaw-notify)
  (error "smoke load: eclaw-notify feature missing"))

(unless (fboundp 'eclaw-chat)
  (error "smoke load: eclaw-chat not bound"))

(unless (gethash "web_search" eclaw--tool-registry)
  (error "smoke load: web_search tool not registered"))
(unless (gethash "web_fetch" eclaw--tool-registry)
  (error "smoke load: web_fetch tool not registered"))

(unless (gethash "send_email" eclaw--tool-registry)
  (error "smoke load: send_email tool not registered"))

(unless (gethash "send_push" eclaw--tool-registry)
  (error "smoke load: send_push tool not registered"))

(unless (gethash "eval_elisp" eclaw--tool-registry)
  (error "smoke load: eval_elisp tool not registered"))

(unless (not (eclaw-tool-policy-enabled-p "eval_elisp"))
  (error "smoke load: eval_elisp should be disabled by default"))

(unless (not (eclaw-tool-policy-enabled-p "send_push"))
  (error "smoke load: send_push should be disabled by default"))

(message "smoke load: OK")
